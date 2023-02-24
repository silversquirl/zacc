const std = @import("std");

pub const gen = @import("gen.zig");
pub const exec = @import("exec.zig");
pub const grammar = @import("grammar.zig");

pub fn ParseTables(
    comptime Term: type,
    comptime NonTerm: type,
) type {
    return struct {
        action: []const ActionMap,
        goto: []const GotoMap,

        pub const Terminal = Term;
        pub const NonTerminal = NonTerm;

        pub const ActionMap = std.enums.EnumArray(Terminal, Action);
        pub const GotoMap = std.enums.EnumArray(NonTerminal, u32);

        pub const Action = union(enum) {
            err,
            done,
            shift: u32,
            reduce: struct { usize, NonTerminal },
        };
    };
}

/// Nice little wrapper struct combining grammar.parseGrammar, gen.Generator and exec.Executor
pub fn Parser(comptime Term: type, comptime src: []const u8) type {
    const result = grammar.Parse(Term, src);
    const tables = gen.Generator(Term, result.NonTerminal).generate(result.grammar);
    const Exec = exec.Executor(Term, result.NonTerminal, tables);

    return struct {
        pub const Terminal = Term;
        pub const NonTerminal = result.NonTerminal;

        pub const ParseTree = Exec.ParseTree;

        pub const parse = Exec.parse;
        pub const parseComptime = Exec.parseComptime;
        pub const parseToTree = Exec.parseToTree;
        pub const parseToTreeComptime = Exec.parseToTreeComptime;
    };
}

pub fn TestTokenizer(comptime Token: type) type {
    return struct {
        toks: [:.sentinel]const Token,
        idx: usize = 0,

        pub fn next(self: *@This()) Token {
            const t = self.toks[self.idx];
            self.idx += 1;
            return t;
        }
    };
}

comptime {
    std.testing.refAllDecls(gen);
    std.testing.refAllDecls(exec);
    std.testing.refAllDecls(grammar);
}

test "parser abstraction - expression" {
    const P = Parser(enum {
        int,
        ident,
        @"+",
        @"*",
        sentinel,
    },
        \\ start = sum $;
        \\ sum = sum '+' prod
        \\     | prod;
        \\ prod = prod '*' value
        \\      | value;
        \\ value = .int | .ident;
    );

    var toks = TestTokenizer(P.Terminal){ .toks = &.{ .ident, .@"*", .int, .@"+", .int } };
    const tree = try P.parseToTree(std.testing.allocator, &toks);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expect(tree.eql(P.ParseTree{
        .nt = .{ .nt = .sum, .children = &.{
            .{ .nt = .{ .nt = .sum, .children = &.{
                .{ .nt = .{ .nt = .prod, .children = &.{
                    .{ .nt = .{ .nt = .prod, .children = &.{
                        .{ .nt = .{ .nt = .value, .children = &.{
                            .{ .t = .ident },
                        } } },
                    } } },
                    .{ .t = .@"*" },
                    .{ .nt = .{ .nt = .value, .children = &.{
                        .{ .t = .int },
                    } } },
                } } },
            } } },
            .{ .t = .@"+" },
            .{ .nt = .{ .nt = .prod, .children = &.{
                .{ .nt = .{ .nt = .value, .children = &.{
                    .{ .t = .int },
                } } },
            } } },
        } },
    }));
}

test "parser abstraction - non-separated list" {
    const P = Parser(enum {
        x,
        sentinel,
    },
        \\ start = seq $;
        \\ seq = seq atom | atom;
        \\ atom = .x;
    );

    var toks = TestTokenizer(P.Terminal){ .toks = &.{ .x, .x } };
    const tree = try P.parseToTree(std.testing.allocator, &toks);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expect(tree.eql(P.ParseTree{
        .nt = .{ .nt = .seq, .children = &.{
            .{ .nt = .{ .nt = .seq, .children = &.{
                .{ .nt = .{ .nt = .atom, .children = &.{
                    .{ .t = .x },
                } } },
            } } },
            .{ .nt = .{ .nt = .atom, .children = &.{
                .{ .t = .x },
            } } },
        } },
    }));
}

test "parser abstraction - comptime" {
    const P = Parser(enum {
        item,
        sep,
        sentinel,
    },
        \\ start = seq $;
        \\ seq = seq .sep .item | .item;
    );

    comptime var toks = TestTokenizer(P.Terminal){ .toks = &.{ .item, .sep, .item, .sep, .item } };
    const tree = comptime try P.parseToTreeComptime(&toks);

    try std.testing.expect(tree.eql(P.ParseTree{
        .nt = .{ .nt = .seq, .children = &.{
            .{ .nt = .{ .nt = .seq, .children = &.{
                .{ .nt = .{ .nt = .seq, .children = &.{
                    .{ .t = .item },
                } } },
                .{ .t = .sep },
                .{ .t = .item },
            } } },
            .{ .t = .sep },
            .{ .t = .item },
        } },
    }));
}
