// Parser for the grammar language
const std = @import("std");
const zlr = @import("zlr.zig");

const Token = enum {
    ident, // Identifier
    char, // any char surrounded by single quotes

    @"$",
    @".",
    @";",
    @"=",
    @"|",

    invalid, // Invalid token
    sentinel, // End of file
};

const Tokenizer = struct {
    src: []const u8,
    idx: usize = 0,
    start: usize = undefined,

    pub fn next(self: *Tokenizer) Token {
        const State = enum {
            start,
            ident,
            char,
            backslash,
        };

        var state = State.start;
        self.start = self.idx;

        while (self.idx < self.src.len) {
            const c = self.src[self.idx];
            self.idx += 1;
            switch (state) {
                .start => {
                    state = switch (c) {
                        ' ', '\t', '\n' => blk: {
                            self.start = self.idx;
                            break :blk .start;
                        },

                        'a'...'z', 'A'...'Z', '_' => .ident,
                        '\'' => .char,

                        '$' => return .@"$",
                        '.' => return .@".",
                        ';' => return .@";",
                        '=' => return .@"=",
                        '|' => return .@"|",

                        else => return .invalid,
                    };
                },

                .ident => switch (c) {
                    'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                    else => {
                        self.idx -= 1;
                        return .ident;
                    },
                },

                .char => switch (c) {
                    '\\' => state = .backslash,
                    '\'' => return .char,
                    else => {},
                },
                .backslash => {},
            }
        }
        return switch (state) {
            .start => .sentinel,
            .ident => .ident,
            .char, .backslash => .invalid,
        };
    }

    fn str(self: Tokenizer) []const u8 {
        return self.src[self.start..self.idx];
    }
};

test "tokenizer - simple grammar" {
    var toks = Tokenizer{ .src = 
    \\start = seq $;
    \\seq = seq .x | .x;
    };

    const expected = [_]struct { Token, usize, usize }{
        .{ .ident, 0, 5 },
        .{ .@"=", 6, 1 },
        .{ .ident, 8, 3 },
        .{ .@"$", 12, 1 },
        .{ .@";", 13, 1 },

        .{ .ident, 15, 3 },
        .{ .@"=", 19, 1 },
        .{ .ident, 21, 3 },
        .{ .@".", 25, 1 },
        .{ .ident, 26, 1 },
        .{ .@"|", 28, 1 },
        .{ .@".", 30, 1 },
        .{ .ident, 31, 1 },
        .{ .@";", 32, 1 },
        .{ .sentinel, 33, 0 },
        .{ .sentinel, 33, 0 },
        .{ .sentinel, 33, 0 },
    };

    for (expected) |e| {
        try std.testing.expectEqual(e[0], toks.next());
        try std.testing.expectEqual(e[1], toks.start);
        try std.testing.expectEqual(e[2], toks.idx - toks.start);
    }
}

// Grammar BNF:
//  start = rules $;
//  rules = rules rule | rule;
//  rule = .ident '=' alts ';';
//  alts = alts '|' pat | pat;
//  pat = pat atom | atom;
//  atom = nonterminal | terminal | sentinel;
//  nonterminal = .ident;
//  terminal = '.' .ident | .char;
//  sentinel = '$';
const grammar = .{
    .start = &.{
        &.{ .{ .nt = .rules }, .{ .t = .sentinel } },
    },
    .rules = &.{
        &.{ .{ .nt = .rules }, .{ .nt = .rule } },
        &.{.{ .nt = .rule }},
    },
    .rule = &.{
        &.{ .{ .t = .ident }, .{ .t = .@"=" }, .{ .nt = .alts }, .{ .t = .@";" } },
    },
    .alts = &.{
        &.{ .{ .nt = .alts }, .{ .t = .@"|" }, .{ .nt = .pat } },
        &.{.{ .nt = .pat }},
    },
    .pat = &.{
        &.{ .{ .nt = .pat }, .{ .nt = .atom } },
        &.{.{ .nt = .atom }},
    },
    .atom = &.{
        &.{.{ .nt = .nonterminal }},
        &.{.{ .nt = .terminal }},
        &.{.{ .nt = .sentinel }},
    },
    .nonterminal = &.{
        &.{.{ .t = .ident }},
    },
    .terminal = &.{
        &.{ .{ .t = .@"." }, .{ .t = .ident } },
        &.{.{ .t = .char }},
    },
    .sentinel = &.{
        &.{.{ .t = .@"$" }},
    },
};
const NonTerm = std.meta.FieldEnum(@TypeOf(grammar));
const tables = zlr.gen.Generator(Token, NonTerm).generate(grammar);
const Exec = zlr.exec.Executor(Token, NonTerm, tables);

pub fn Parse(comptime Terminal: type, comptime src: []const u8) type {
    const ir = parseToIr(src);
    return struct {
        pub const NonTerminal = blk: {
            var nonterms: [ir.len]std.builtin.Type.EnumField = undefined;
            for (&nonterms, ir, 0..) |*field, rule, i| {
                field.* = .{
                    .name = rule.name,
                    .value = i,
                };
            }
            break :blk @Type(.{ .Enum = .{
                .tag_type = std.math.IntFittingRange(0, nonterms.len),
                .fields = &nonterms,
                .decls = &.{},
                .is_exhaustive = true,
            } });
        };

        pub const Grammar = std.enums.EnumFieldStruct(
            NonTerminal,
            []const []const zlr.gen.Symbol(Terminal, NonTerminal),
            null,
        );

        pub const grammar = blk: {
            const Symbol = zlr.gen.Symbol(Terminal, NonTerminal);

            var g: Grammar = undefined;
            for (ir) |rule| {
                var alts: [rule.alts.len][]const Symbol = undefined;
                for (&alts, rule.alts) |*g_alt, alt| {
                    var syms: [alt.len]Symbol = undefined;
                    for (&syms, alt) |*g_sym, sym| {
                        g_sym.* = switch (sym.kind) {
                            .terminal => .{ .t = @field(Terminal, sym.name) },
                            .nonterminal => .{ .nt = @field(NonTerminal, sym.name) },
                        };
                    }
                    g_alt.* = &syms;
                }
                @field(g, rule.name) = &alts;
            }
            break :blk g;
        };
    };
}

fn parseToIr(comptime src: []const u8) []const IrRule {
    comptime {
        const Context = struct {
            toks: *Tokenizer,
            const Context = @This();

            pub const Result = union(enum) {
                rules: []const IrRule,
                rule: IrRule,
                alts: []const []const IrRule.Atom,
                pat: []const IrRule.Atom,
                atom: IrRule.Atom,
                ident: []const u8,
                unused,
            };

            pub fn nonTerminal(
                comptime _: Context,
                comptime nt: NonTerm,
                comptime children: []const Result,
            ) !Result {
                return switch (nt) {
                    .start => unreachable,
                    .rules => seq("rules", "rule", 1, children),
                    .rule => .{ .rule = .{
                        .name = children[0].ident,
                        .alts = children[2].alts,
                    } },
                    .alts => seq("alts", "pat", 2, children),
                    .pat => seq("pat", "atom", 1, children),
                    .atom => children[0],
                    .nonterminal => .{ .atom = .{
                        .kind = .nonterminal,
                        .name = children[0].ident,
                    } },
                    .terminal => .{ .atom = .{
                        .kind = .terminal,
                        .name = children[children.len - 1].ident,
                    } },
                    .sentinel => .{ .atom = .{
                        .kind = .terminal,
                        .name = "sentinel",
                    } },
                };
            }
            pub fn terminal(comptime self: Context, comptime t: Token) !Result {
                return switch (t) {
                    .ident => .{ .ident = self.toks.str() },
                    .char => blk: {
                        const result = std.zig.parseCharLiteral(self.toks.str());
                        if (result == .failure) {
                            return error.ParseInvalidChar;
                        }
                        const str = std.fmt.comptimePrint("{u}", .{result.success});
                        break :blk .{ .ident = str };
                    },
                    else => .unused,
                };
            }

            fn seq(
                comptime rule: []const u8,
                comptime item: []const u8,
                comptime item_idx: usize,
                comptime children: []const Result,
            ) Result {
                return @unionInit(
                    Result,
                    rule,
                    if (children.len > 1)
                        @field(children[0], rule) ++ .{@field(children[item_idx], item)}
                    else
                        &.{@field(children[0], item)},
                );
            }
        };

        var toks = Tokenizer{ .src = src };
        const result = Exec.parseComptime(
            &toks,
            Context{ .toks = &toks },
        ) catch @compileError("Parse error"); // TODO: errors
        return result.rules;
    }
}
const IrRule = struct {
    name: []const u8,
    alts: []const []const Atom,
    const Atom = struct {
        kind: enum { terminal, nonterminal },
        name: []const u8,
    };
};

test "parser - simple grammar" {
    const result = Parse(enum { x, sentinel },
        \\start = seq $;
        \\seq = seq .x | .x;
    );

    try expectEqualRules(result.grammar, .{
        .start = &.{
            &.{ .{ .nt = .seq }, .{ .t = .sentinel } },
        },
        .seq = &.{
            &.{ .{ .nt = .seq }, .{ .t = .x } },
            &.{.{ .t = .x }},
        },
    });
}

test "parser - grammar grammar" {
    const result = Parse(Token,
        \\  start = rules $;
        \\  rules = rules rule | rule;
        \\  rule = .ident '=' alts ';';
        \\  alts = alts '|' pat | pat;
        \\  pat = pat atom | atom;
        \\  atom = nonterminal | terminal | sentinel;
        \\  nonterminal = .ident;
        \\  terminal = '.' .ident | .char;
        \\  sentinel = '$';
    );

    try expectEqualRules(result.grammar, grammar);
}

fn expectEqualRules(actual: anytype, expected: @TypeOf(actual)) !void {
    inline for (comptime std.meta.fieldNames(@TypeOf(actual))) |name| {
        const rule_a = @field(actual, name);
        const rule_e = @field(expected, name);
        for (rule_a, rule_e) |pat_a, pat_e| {
            for (pat_a, pat_e) |sym_a, sym_e| {
                if (!std.meta.eql(sym_a, sym_e)) {
                    std.debug.print("Expected {s}, found {s}\n", .{ @tagName(sym_e), @tagName(sym_a) });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}
