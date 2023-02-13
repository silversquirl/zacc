const std = @import("std");

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
