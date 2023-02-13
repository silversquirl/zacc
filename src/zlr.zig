const std = @import("std");

pub const gen = @import("gen.zig");
pub const exec = @import("exec.zig");

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

pub fn Parser(comptime Token: type, comptime grammar: anytype) type {
    return struct {
        pub const Terminal = Token;
        pub const NonTerminal = std.meta.FieldEnum(@TypeOf(grammar));

        const tables = gen.Generator(Terminal, NonTerminal).generate(grammar);
        const Exec = exec.Executor(Terminal, NonTerminal, tables);
        pub const ParseTree = Exec.ParseTree;

        pub fn parse(allocator: std.mem.Allocator, tokenizer: anytype) !ParseTree {
            return Exec.parseToTree(allocator, tokenizer);
        }
    };
}

comptime {
    @import("std").testing.refAllDecls(gen);
}

test {
    const P = Parser(enum {
        int,
        ident,
        plus,
        times,
        sentinel,
    }, .{
        // start = sum END
        .start = &.{
            &.{ .{ .nt = .sum }, .{ .t = .sentinel } },
        },
        // sum = sum '+' prod
        //     | prod
        .sum = &.{
            &.{ .{ .nt = .sum }, .{ .t = .plus }, .{ .nt = .prod } },
            &.{.{ .nt = .prod }},
        },
        // prod = prod '*' value
        //      | value
        .prod = &.{
            &.{ .{ .nt = .prod }, .{ .t = .times }, .{ .nt = .value } },
            &.{.{ .nt = .value }},
        },
        // value = INT | IDENT
        .value = &.{
            &.{.{ .t = .int }},
            &.{.{ .t = .ident }},
        },
    });

    const T = struct {
        toks: [:.sentinel]const P.Terminal,
        idx: usize = 0,

        pub fn next(self: *@This()) P.Terminal {
            const t = self.toks[self.idx];
            self.idx += 1;
            return t;
        }
    };

    var toks = T{ .toks = &.{ .ident, .times, .int, .plus, .int } };
    const tree = try P.parse(std.testing.allocator, &toks);
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
                    .{ .t = .times },
                    .{ .nt = .{ .nt = .value, .children = &.{
                        .{ .t = .int },
                    } } },
                } } },
            } } },
            .{ .t = .plus },
            .{ .nt = .{ .nt = .prod, .children = &.{
                .{ .nt = .{ .nt = .value, .children = &.{
                    .{ .t = .int },
                } } },
            } } },
        } },
    }));
}
