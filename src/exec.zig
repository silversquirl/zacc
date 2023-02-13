const std = @import("std");
const common = @import("common.zig");

pub fn Executor(
    comptime Terminal: type,
    comptime NonTerminal: type,
) type {
    return struct {
        pub fn parseToTree(
            allocator: std.mem.Allocator,
            comptime tables: Tables,
            tokenizer: anytype,
        ) !ParseTree {
            var stack = std.ArrayList(struct { u32, ParseTree }).init(allocator);
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
                            .{ .t = tok },
                        });
                        tok = tokenizer.next(); // TODO: allow errors
                    },

                    .reduce => |red| {
                        const children = try allocator.alloc(ParseTree, red[0]);
                        errdefer allocator.free(children);
                        const pop_idx = stack.items.len - children.len;
                        for (stack.items[pop_idx..]) |entry, j| {
                            children[j] = entry[1];
                        }
                        stack.shrinkRetainingCapacity(pop_idx);

                        const prior_state = stack.getLast()[0];
                        const next_state = tables.goto[prior_state].get(red[1]);
                        if (next_state == std.math.maxInt(u32)) {
                            return error.ParseSyntaxError;
                        }
                        try stack.append(.{
                            next_state,
                            .{ .nt = .{
                                .nt = red[1],
                                .children = children,
                            } },
                        });
                    },

                    .done => return stack.pop()[1],
                    .err => return error.ParseSyntaxError,
                }
            }
        }

        pub const Tables = common.ParseTables(Terminal, NonTerminal);
        pub const ParseTree = union(enum) {
            nt: struct {
                nt: NonTerminal,
                children: []const ParseTree,
            },
            t: Terminal,

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

            pub fn eql(self: ParseTree, other: ParseTree) bool {
                if (@as(std.meta.Tag(ParseTree), self) != other) return false;
                switch (self) {
                    .nt => |nt| {
                        for (nt.children) |t, i| {
                            if (!t.eql(other.nt.children[i])) {
                                return false;
                            }
                        }
                        return true;
                    },
                    .t => |t| return t == other.t,
                }
            }

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
