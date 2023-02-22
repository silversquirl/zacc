const std = @import("std");
const zlr = @import("zlr.zig");

pub fn Executor(
    comptime Terminal: type,
    comptime NonTerminal: type,
    comptime tables: zlr.ParseTables(Terminal, NonTerminal),
) type {
    return struct {
        pub fn parse(
            allocator: std.mem.Allocator,
            tokenizer: anytype,
            context: anytype,
        ) !@TypeOf(context).Result {
            return parseInternal(false, allocator, tokenizer, context);
        }

        pub fn parseComptime(
            comptime tokenizer: anytype,
            context: anytype,
        ) !@TypeOf(context).Result {
            comptime {
                return parseInternal(true, undefined, tokenizer, context);
            }
        }

        fn parseInternal(
            comptime ct: bool,
            allocator: std.mem.Allocator,
            tokenizer: anytype,
            context: anytype,
        ) !@TypeOf(context).Result {
            const Result = @TypeOf(context).Result;

            var stack = Stack(ct, struct { u32, Result }).init(allocator);
            defer stack.deinit();
            try stack.push(.{ 0, undefined });

            var tok: Terminal = tokenizer.next(); // TODO: allow errors (eg. file read)

            while (true) {
                const state = stack.top()[0];
                const action = tables.action[state].get(tok);
                switch (action) {
                    .shift => |next_state| {
                        try stack.push(.{
                            next_state,
                            try context.terminal(tok),
                        });
                        tok = tokenizer.next(); // TODO: allow errors
                    },

                    .reduce => |reduce| {
                        const count = reduce[0];
                        const nt = reduce[1];

                        var children: [max_pop]Result = undefined;
                        for (stack.popMany(count), 0..) |entry, j| {
                            children[j] = entry[1];
                        }

                        const prior_state = stack.top()[0];
                        const next_state = tables.goto[prior_state].get(nt);
                        if (next_state == std.math.maxInt(u32)) {
                            return error.ParseSyntaxError;
                        }
                        try stack.push(.{
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

        fn Stack(comptime ct: bool, comptime T: type) type {
            return if (ct) struct {
                array: []T,

                pub inline fn init(_: std.mem.Allocator) @This() {
                    return .{ .array = &.{} };
                }
                pub inline fn deinit(_: @This()) void {}

                pub inline fn push(comptime self: *@This(), item: T) !void {
                    var a = (self.array ++ .{item}).*;
                    self.array = &a;
                }

                pub inline fn top(comptime self: @This()) T {
                    return self.array[self.array.len - 1];
                }

                pub inline fn pop(comptime self: *@This()) T {
                    return self.popMany(1)[0];
                }

                // The returned array is invalidated as soon as the stack is pushed to
                pub inline fn popMany(comptime self: *@This(), count: usize) []T {
                    const pop_idx = self.array.len - count;
                    const a = self.array[pop_idx..];
                    self.array = self.array[0..pop_idx];
                    return a;
                }
            } else struct {
                array: std.ArrayList(T),

                pub inline fn init(allocator: std.mem.Allocator) @This() {
                    return .{ .array = std.ArrayList(T).init(allocator) };
                }

                pub inline fn deinit(self: *@This()) void {
                    for (self.array.items[1..]) |entry| {
                        entry[1].deinit(self.array.allocator);
                    }
                    self.array.deinit();
                }

                pub inline fn push(self: *@This(), item: T) !void {
                    try self.array.append(item);
                }

                pub inline fn top(self: @This()) T {
                    return self.array.getLast();
                }

                pub inline fn pop(self: *@This()) T {
                    return self.array.pop();
                }

                // The returned array is invalidated as soon as the stack is pushed to
                pub inline fn popMany(self: *@This(), count: usize) []T {
                    const pop_idx = self.array.items.len - count;
                    const a = self.array.items[pop_idx..];
                    self.array.shrinkRetainingCapacity(pop_idx);
                    return a;
                }
            };
        }

        pub fn parseToTree(
            allocator: std.mem.Allocator,
            tokenizer: anytype,
        ) !ParseTree {
            return parse(
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

        pub fn parseToTreeComptime(
            comptime tokenizer: anytype,
        ) !ParseTree {
            return parseComptime(
                tokenizer,
                ParseTreeComptimeContext{},
            );
        }
        const ParseTreeComptimeContext = struct {
            pub const Result = ParseTree;

            pub fn nonTerminal(
                _: ParseTreeComptimeContext,
                nt: NonTerminal,
                comptime children: []const ParseTree,
            ) !ParseTree {
                return .{ .nt = .{
                    .nt = nt,
                    .children = children ++ .{},
                } };
            }
            pub fn terminal(_: ParseTreeComptimeContext, t: Terminal) !ParseTree {
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
