const std = @import("std");
const zacc = @import("zacc");

const Token = enum {
    sentinel, // Marks end of file. Every token type used by Zacc must have this token
    number,

    // Single-character tokens can be written using character syntax in Zacc
    // grammars, so we use Zig's quoted literal syntax to define these oeprators.
    @"+",
    @"-",
    @"*",
    @"/",
    @"(",
    @")",
};

const Parser = zacc.Parser(Token,
    \\ // Every grammar must have a start rule, which must follow the form `start = nonterminal $`
    \\ start = sum $;
    \\ // This rule represents a sum expression
    \\ sum = sum '+' prod
    \\     | sum '-' prod
    \\     | prod;
    \\ // This rule represents a product expression
    \\ prod = prod '*' atom
    \\      | prod '/' atom
    \\      | atom;
    \\ // This rule represents an "atom" - either a number or a parenthesized expression
    \\ atom = .number | '(' sum ')';
);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var toks = zacc.TestTokenizer(Token){ .toks = &.{
        .number,
        .@"+",
        .number,
        .@"*",
        .@"(",
        .number,
        .@"-",
        .number,
        .@")",
        .@"/",
        .number,
    } };
    const tree = try Parser.parseToTree(arena.allocator(), &toks);
    try std.io.getStdOut().writer().print("{}\n", .{tree.fmtDot()});
}

// TODO:
// - tokenizer
// - use context to build AST
// - use context to perform arithmetic while parsing
