# Zacc

Zacc is a parser generator for Zig. It uses LR(1) for linear-time bottom-up parsing, will parse into any AST you can dream up, and works at both comptime and runtime!

## Status

Parsing works great, but error reporting is a work in progress.
Grammar syntax could do with some ergonomic improvements for things like repetitions, optionals, etc.

## Usage

Zacc can be added as a dependency through the Zig package manager.
Simply add the following to the `dependencies` field in your `build.zig.zon`:

```zig
.zacc = .{
    .url = "https://github.com/silversquirl/zacc/archive/<COMMIT HASH GOES HERE>.tar.gz",
    .hash = "<SHA2 CHECKSUM GOES HERE>",
},
```

Then you can add the module in your `build.zig`:

```zig
exe.addModule("zacc", b.dependency("zacc", .{}).module("zacc"));
```

To create a parser with Zacc, you need:

- a `Token` enum containing at least a `sentinel` option (which signals the end of the input)
- a tokenizer struct with a `pub fn next(self) Token`
- a grammar written in a BNF-style format

Then you can call `const Parser = zacc.Parser(Token, grammar)` to construct a parser, followed by `Parser.parseToTree(allocator, &tokenizer)` to parse from the tokenizer.
The resulting parse tree is useful for debugging purposes, and can be printed in Graphviz DOT format using `tree.fmtDot()`, however once your grammar works correctly you should parse to an AST using the callback API.

To do this, call `parse` instead of `parseToTree`, and pass in a `context` parameter.
Your context type should have the following decls:

- `pub const Result: type`
- `pub fn nonTerminal(self, Parser.NonTerminal, []const Result) !Result`
- `pub fn terminal(self, Token) !Result` (`Token` is also available as `Parser.Terminal`)

The `terminal` callback will be called when a non-terminal symbol is parsed, and will be passed in the corresponding token.
The `nonTerminal` callback will be called when a non-terminal symbol has been parsed, and is passed the symbol name as an enum value, as well as the children of the symbol, in the same order as defined in the grammar.

For an example that uses Zacc to parse basic arithmetic expressions, see `example/arithmetic.zig`
