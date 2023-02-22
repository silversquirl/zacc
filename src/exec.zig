const std = @import("std");
const zlr = @import("zlr.zig");

pub fn Executor(
    comptime Terminal: type,
    comptime NonTerminal: type,
    comptime tables: zlr.ParseTables(Terminal, NonTerminal),
) type {
    return struct {
        pub fn parseWithContext(
            allocator: std.mem.Allocator, // TODO: use recursion instead?
            tokenizer: anytype,
            context: anytype,
        ) !@TypeOf(context).Result {
            const Result = @TypeOf(context).Result;

            var stack = std.ArrayList(struct { u32, Result }).init(allocator);
            defer {
                for (stack.items[1..]) |entry| {
                    entry[1].deinit(allocator);
                }
                stack.deinit();
            }
            try stack.append(.{ 0, undefined });

            var tok: Terminal = tokenizer.next(); // TODO: allow errors (eg. file read)

            while (true) {
                const state = stack.getLast()[0];
                const action = tables.action[state].get(tok);
                switch (action) {
                    .shift => |next_state| {
                        try stack.append(.{
                            next_state,
                            try context.terminal(tok),
                        });
                        tok = tokenizer.next(); // TODO: allow errors
                    },

                    .reduce => |reduce| {
                        const count = reduce[0];
                        const nt = reduce[1];

                        var children: [max_pop]Result = undefined;
                        const pop_idx = stack.items.len - count;
                        for (stack.items[pop_idx..], 0..) |entry, j| {
                            children[j] = entry[1];
                        }
                        stack.shrinkRetainingCapacity(pop_idx);

                        const prior_state = stack.getLast()[0];
                        const next_state = tables.goto[prior_state].get(nt);
                        if (next_state == std.math.maxInt(u32)) {
                            return error.ParseSyntaxError;
                        }
                        try stack.append(.{
                            next_state,
                            try context.nonTerminal(nt, @as([]const Result, children[0..count])),
                        });
                    },

                    .done => return stack.pop()[1],
                    .err => return error.ParseSyntaxError,
                }
            }
        }

        const max_pop = blk: {
            var max: u32 = 0;
            for (tables.action) |action_map| {
                for (action_map.values) |action| {
                    if (action == .reduce) {
                        max = @max(max, action.reduce[0]);
                    }
                }
            }
            break :blk max;
        };

        pub fn parseToTree(
            allocator: std.mem.Allocator,
            tokenizer: anytype,
        ) !ParseTree {
            return parseWithContext(
                allocator,
                tokenizer,
                ParseTreeContext{ .allocator = allocator },
            );
        }
        const ParseTreeContext = struct {
            allocator: std.mem.Allocator,

            pub const Result = ParseTree;

            pub fn nonTerminal(
                self: ParseTreeContext,
                nt: NonTerminal,
                children: []const ParseTree,
            ) !ParseTree {
                return .{ .nt = .{
                    .nt = nt,
                    .children = try self.allocator.dupe(ParseTree, children),
                } };
            }
            pub fn terminal(_: ParseTreeContext, t: Terminal) !ParseTree {
                return .{ .t = t };
            }
        };

        pub const ParseTree = union(enum) {
            nt: struct {
                nt: NonTerminal,
                children: []const ParseTree,
            },
            t: Terminal,

            /// Free the parse tree.
            pub fn deinit(self: ParseTree, allocator: std.mem.Allocator) void {
                switch (self) {
                    .nt => |nt| {
                        for (nt.children) |t| {
                            t.deinit(allocator);
                        }
                        allocator.free(nt.children);
                    },
                    .t => {},
                }
            }

            /// Compare two parse trees. Useful for tests.
            pub fn eql(self: ParseTree, other: ParseTree) bool {
                if (@as(std.meta.Tag(ParseTree), self) != other) return false;
                switch (self) {
                    .nt => |nt| {
                        for (nt.children, 0..) |t, i| {
                            if (!t.eql(other.nt.children[i])) {
                                return false;
                            }
                        }
                        return true;
                    },
                    .t => |t| return t == other.t,
                }
            }

            /// Format the parse tree as a Graphviz DOT graph. Useful for debugging.
            pub fn fmtDot(self: ParseTree) std.fmt.Formatter(formatDot) {
                return .{ .data = self };
            }
            fn formatDot(self: ParseTree, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
                _ = fmt;
                _ = options;
                try writer.writeAll("digraph {\n");
                var i: usize = 0;
                _ = try self.formatDotRec(writer, &i);
                try writer.writeAll("}\n");
            }
            fn formatDotRec(self: ParseTree, writer: anytype, i: *usize) !usize {
                const id = i.*;
                i.* += 1;
                try writer.print("\t{} [label=\"{s}\"];\n", .{
                    id,
                    switch (self) {
                        .nt => |nt| @tagName(nt.nt),
                        .t => |t| @tagName(t),
                    },
                });
                switch (self) {
                    .nt => |nt| for (nt.children) |child| {
                        const child_id = try child.formatDotRec(writer, i);
                        try writer.print("\t{} -> {};\n", .{ id, child_id });
                    },
                    .t => try writer.print("\t{{ rank=max; {}; }}\n", .{id}),
                }
                return id;
            }
        };
    };
}
