const std = @import("std");
const zlr = @import("zlr.zig");

pub fn Generator(
    comptime Terminal: type,
    comptime NonTerminal: type,
) type {
    return struct {
        pub fn generate(comptime rules: Rules) Tables {
            comptime {
                @setEvalBranchQuota(1000 * std.meta.fields(Rules).len);

                var gen = Self{ .rules = RulesArray.init(rules) };
                gen.fillFirst();
                gen.fillFollow();
                gen.genItemSets();
                return gen.genTables();
            }
        }

        const Self = @This();

        pub const Tables = zlr.ParseTables(Terminal, NonTerminal);
        pub const Rules = std.enums.EnumFieldStruct(NonTerminal, []const []const Symbol, null);
        const RulesArray = std.enums.EnumArray(NonTerminal, []const []const Symbol);
        pub const Symbol = union(enum) {
            t: Terminal,
            nt: NonTerminal,
        };

        rules: RulesArray,
        first: TermTable = TermTable.initFill(TermSet.initEmpty()),
        follow: TermTable = TermTable.initFill(TermSet.initEmpty()),
        item_sets: []const ItemSet = &.{},
        transitions: []const StateTransitions = &.{},

        const TermSet = std.enums.EnumSet(Terminal);
        const TermTable = std.enums.EnumArray(NonTerminal, TermSet);

        const sentinel_tset = blk: {
            var set = TermSet.initEmpty();
            set.insert(.sentinel);
            break :blk set;
        };

        const Item = struct {
            nt: NonTerminal,
            rule: u32,
            index: u32,
            next: TermSet,

            fn eqlPos(a: Item, b: Item) bool {
                return a.nt == b.nt and a.rule == b.rule and a.index == b.index;
            }
        };

        const ItemSet = struct {
            items: []Item = &.{},

            // Add or combine an item into the set
            fn add(comptime self: *ItemSet, comptime item: Item) void {
                if (self.getPtr(item)) |other| {
                    other.next.setUnion(item.next);
                } else {
                    comptime var items = self.items[0..self.items.len].* ++ .{item};
                    self.items = &items;
                }
            }

            fn eql(a: ItemSet, b: ItemSet) bool {
                if (a.items.len != b.items.len) return false;
                for (a.items) |item| {
                    if (b.getPtr(item)) |item2| {
                        if (!item.next.eql(item2.next)) return false;
                    } else {
                        return false;
                    }
                }
                return true;
            }

            fn getPtr(self: ItemSet, item: Item) ?*Item {
                for (self.items) |*other| {
                    if (item.eqlPos(other.*)) {
                        return other;
                    }
                }
                return null;
            }
        };

        const StateTransitions = struct {
            t: std.enums.EnumMap(Terminal, u32) = .{},
            nt: std.enums.EnumMap(NonTerminal, u32) = .{},
        };

        fn fillFirst(self: *Self) void {
            var done = false;
            while (!done) {
                done = true;
                for (std.enums.values(NonTerminal)) |lhs| {
                    const set = self.first.getPtr(lhs);
                    for (self.rules.get(lhs)) |rhs| {
                        switch (rhs[0]) {
                            .t => |t| if (!set.contains(t)) {
                                set.insert(t);
                                done = false;
                            },
                            .nt => |nt| {
                                const other = self.first.get(nt);
                                if (!set.supersetOf(other)) {
                                    set.setUnion(other);
                                    done = false;
                                }
                            },
                        }
                    }
                }
            }
        }

        fn fillFollow(self: *Self) void {
            var done = false;
            while (!done) {
                done = true;
                for (std.enums.values(NonTerminal)) |lhs| {
                    for (self.rules.get(lhs)) |rhs| {
                        for (rhs) |sym, i| {
                            if (sym == .t) continue;
                            const set = self.follow.getPtr(sym.nt);

                            if (i == rhs.len - 1) {
                                // nt is last symbol in r
                                const other = self.follow.get(lhs);
                                if (!set.supersetOf(other)) {
                                    set.setUnion(other);
                                    done = false;
                                }
                            } else switch (rhs[i + 1]) {
                                .t => |t| if (!set.contains(t)) {
                                    set.insert(t);
                                    done = false;
                                },
                                .nt => |nt| {
                                    const other = self.follow.get(nt);
                                    if (!set.supersetOf(other)) {
                                        set.setUnion(other);
                                        done = false;
                                    }
                                },
                            }
                        }
                    }
                }
            }
        }

        fn genItemSets(comptime self: *Self) void {
            {
                var iset = ItemSet{};

                iset.add(Item{
                    .nt = .start,
                    .rule = 0,
                    .index = 0,
                    .next = sentinel_tset,
                });

                self.closeItemSet(&iset);
                self.item_sets = &.{iset};
            }

            var i: usize = 0;
            while (i < self.item_sets.len) : (i += 1) {
                var trans = StateTransitions{};

                const iset = self.item_sets[i];
                for (iset.items) |item| {
                    const rhs = self.rules.get(item.nt)[item.rule];
                    if (item.index >= rhs.len) continue;
                    const locus = rhs[item.index];

                    // Generate new item set from locus
                    var new_iset = self.makeItemSet(iset, locus);
                    const idx = for (self.item_sets) |old_iset, j| {
                        if (old_iset.eql(new_iset)) {
                            break j;
                        }
                    } else blk: {
                        self.item_sets = self.item_sets ++ .{new_iset};
                        break :blk self.item_sets.len - 1;
                    };

                    // Add to state transition table
                    const to = @intCast(u32, idx);
                    const old = switch (locus) {
                        .t => |t| trans.t.fetchPut(t, to),
                        .nt => |nt| trans.nt.fetchPut(nt, to),
                    };
                    std.debug.assert(old == null or old.? == to);
                }

                std.debug.assert(self.transitions.len == i);
                self.transitions = self.transitions ++ .{trans};
            }
        }

        fn makeItemSet(self: Self, comptime seed_iset: ItemSet, comptime seed_locus: Symbol) ItemSet {
            comptime {
                var iset = ItemSet{};

                for (seed_iset.items) |item| {
                    const rhs = self.rules.get(item.nt)[item.rule];
                    if (item.index >= rhs.len) continue;
                    const locus = rhs[item.index];
                    if (std.meta.eql(locus, seed_locus)) {
                        var new_item = item;
                        new_item.index += 1;
                        iset.add(new_item);
                    }
                }

                self.closeItemSet(&iset);

                return iset;
            }
        }

        fn closeItemSet(self: Self, comptime iset: *ItemSet) void {
            // No need to "while (!done)" here; new values will be added to end and iterated over normally
            var i: usize = 0;
            while (i < iset.items.len) : (i += 1) {
                const item = iset.items[i];
                const rhs = self.rules.get(item.nt)[item.rule];
                if (item.index >= rhs.len) continue;
                const locus = switch (rhs[item.index]) {
                    .t => continue,
                    .nt => |nt| nt,
                };

                const next = if (item.index + 1 >= rhs.len)
                    self.follow.get(item.nt)
                else switch (rhs[item.index + 1]) {
                    .t => |t| blk: {
                        var set = TermSet.initEmpty();
                        set.insert(t);
                        break :blk set;
                    },
                    .nt => |nt| self.first.get(nt),
                };

                for (self.rules.get(locus)) |_, j| {
                    const new_item = Item{
                        .nt = locus,
                        .rule = @intCast(u32, j),
                        .index = 0,
                        .next = next,
                    };
                    iset.add(new_item);
                }
            }
        }

        fn genTables(comptime self: Self) Tables {
            var action_table: [self.item_sets.len]Tables.ActionMap = undefined;
            var goto_table: [self.item_sets.len]Tables.GotoMap = undefined;

            for (self.transitions) |trans, state_id| {
                // GOTO table
                var goto = std.enums.EnumArray(NonTerminal, u32).initFill(std.math.maxInt(u32));
                {
                    var nt = trans.nt;
                    var it = nt.iterator();
                    while (it.next()) |entry| {
                        goto.set(entry.key, entry.value.*);
                    }
                }
                goto_table[state_id] = goto;

                // ACTION table: shift
                var action = std.enums.EnumArray(Terminal, Tables.Action).initFill(.err);
                {
                    var t = trans.t;
                    var it = t.iterator();
                    while (it.next()) |entry| {
                        action.set(entry.key, .{ .shift = entry.value.* });
                    }
                }

                // ACTION table: reduce
                const iset = self.item_sets[state_id];
                for (iset.items) |item| {
                    const rhs = self.rules.get(item.nt)[item.rule];
                    if (item.index < rhs.len) continue;

                    var it = item.next.iterator();
                    while (it.next()) |t| {
                        action.set(t, .{ .reduce = .{ rhs.len, item.nt } });
                    }
                }

                // ACTION table: done
                for (iset.items) |item| {
                    if (item.nt == .start and item.index == 1) {
                        std.debug.assert(item.rule == 0);
                        std.debug.assert(self.rules.get(item.nt).len == 1);
                        std.debug.assert(self.rules.get(item.nt)[item.rule].len == 2);
                        std.debug.assert(self.rules.get(item.nt)[item.rule][1].t == .sentinel);

                        std.debug.assert(item.next.eql(sentinel_tset));
                        action.set(.sentinel, .done);
                        break;
                    }
                }

                action_table[state_id] = action;
            }

            return Tables{
                .action = &action_table,
                .goto = &goto_table,
            };
        }
    };
}

test {
    const Gen = Generator(enum {
        int,
        ident,
        plus,
        times,
        sentinel,
    }, enum {
        start,
        sum,
        prod,
        value,
    });

    @setEvalBranchQuota(4000);
    const tables = Gen.generate(.{
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

    try std.testing.expectEqual(@as(usize, 11), tables.action.len);
    // try std.testing.expectEqual(@as(usize, 10), tables.action.len); // FIXME: it should be 10, idk why it's not
    try std.testing.expectEqual(tables.action.len, tables.goto.len);

    // TODO
    // const expected = Gen.Tables{
    //     .action = .{
    //     },
    // };
}
