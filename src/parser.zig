const std = @import("std");
const ptk = @import("parser-toolkit");
const matchers = ptk.matchers;

const Allocator = *std.mem.Allocator;

pub const Parser = struct {
    core: ParserCore,
    allocator: Allocator,

    const TokenType = enum {
        number,
        identifier,
        whitespace,
        linefeed,
        @"(",
        @")",
        @",",
        @"+",
        @";",
        define,
    };

    const Pattern = ptk.Pattern(TokenType);

    const Tokenizer = ptk.Tokenizer(TokenType, &[_]Pattern{
        Pattern.create(.number, matchers.sequenceOf(.{ matchers.decimalNumber })),
        Pattern.create(.identifier, matchers.identifier),
        Pattern.create(.linefeed, matchers.linefeed),
        Pattern.create(.whitespace, matchers.whitespace),
        Pattern.create(.@"+", matchers.literal("+")),
        Pattern.create(.@"(", matchers.literal("(")),
        Pattern.create(.@")", matchers.literal(")")),
        Pattern.create(.@",", matchers.literal(",")),
        Pattern.create(.@";", matchers.literal(";")),
        Pattern.create(.define, matchers.literal("=")),
    });

    const ParserCore = ptk.ParserCore(Tokenizer, .{ .whitespace });
    const ruleset = ptk.RuleSet(TokenType);

    pub fn parse(allocator: Allocator, block: []const u8) !Block {
        var tokenizer = Tokenizer.init(block);
        std.log.debug("parse {s}", .{ block });

        var parser = Parser {
            .core = ParserCore.init(&tokenizer),
            .allocator = allocator
        };

        const root = try parser.acceptBlock();
        errdefer allocator.free(root);

        if ((try parser.core.peek()) != null) {
            const str = parser.core.tokenizer.source[parser.core.tokenizer.offset..];
            std.log.info("remaining: {s}", .{ str });
            return error.SyntaxError;
        }

        return root;
    }

    const Error = ParserCore.Error || std.mem.Allocator.Error || std.fmt.ParseFloatError;

    pub const FunctionCall = struct {
        name: []const u8,
        // args: void
    };

    pub const Statement = union(enum) {
        SetLocal: struct {
            name: []const u8,
            value: Expression
        },
        FunctionCall: FunctionCall,
    };

    pub const Number = []const u8;
    pub const Block = []Statement;

    pub const Expression = union(enum) {
        // TODO: pointers to expression instead of number
        Add: struct { lhs: Number, rhs: Number },
        FunctionCall: FunctionCall,
    };

    pub fn acceptBlock(self: *Parser) Error!Block {
        const state = self.core.saveState();
        errdefer self.core.restoreState(state);

        var statements = std.ArrayList(Statement).init(self.allocator);
        errdefer statements.deinit();

        while (self.acceptStatement()) |optStat| {
            if (optStat) |stat| {
                try statements.append(stat);
            }
        } else |err| {
            switch (err) {
                error.EndOfStream => {},
                else => return err
            }
        }

        return statements.toOwnedSlice();
    }

    pub fn acceptStatement(self: *Parser) Error!?Statement {
        const state = self.core.saveState();
        errdefer self.core.restoreState(state);

        if (self.acceptFunctionCall()) |call| {
           if (call) |result| {
               _ = try self.core.accept(comptime ruleset.oneOf(.{ .linefeed, .@";" }));
               return Statement { .FunctionCall = result };
           } else |err| return err;
        } else {
            if (self.acceptLocalDefinition()) |expr| {
                if (expr) |result| {
                    _ = try self.core.accept(comptime ruleset.oneOf(.{ .linefeed, .@";" }));
                    return result;
                } else |err| return err;
            } else {
                // std.log.info("{}", .{ try self.core.peek() });
                _ = try self.core.accept(comptime ruleset.oneOf(.{ .linefeed, .@";" }));
                return null;
            }
        }
    }

    pub fn acceptLocalDefinition(self: *Parser) ?Error!Statement {
        const state = self.core.saveState();
        errdefer self.core.restoreState(state);

        const id = self.core.accept(comptime ruleset.is(.identifier)) catch {
            self.core.restoreState(state); return null; };

        _ = self.core.accept(comptime ruleset.is(.define)) catch {
            self.core.restoreState(state); return null; };

        const expr = try self.acceptExpression();

        return Statement {
            .SetLocal = .{
                .name = id.text,
                .value = expr
            }
        };
    }

    pub fn acceptFunctionCall(self: *Parser) ?Error!FunctionCall {
        const state = self.core.saveState();
        errdefer self.core.restoreState(state);

        const id = self.core.accept(comptime ruleset.is(.identifier)) catch {
            self.core.restoreState(state); return null; };

        _ = self.core.accept(comptime ruleset.is(.@"(")) catch {
            self.core.restoreState(state); return null; };

        var first = true;
        while (true) {
            if (!first) {
                _ = self.core.accept(comptime ruleset.is(.@",")) catch |err| switch (err) {
                    error.UnexpectedToken => break,
                    else => return err
                };
            }

            const arg = self.acceptExpression() catch |err| if (first) switch (err) {
                error.UnexpectedToken => break,
                else => return err
            } else return err;
            _ = arg;

            first = false;
        }

        _ = try self.core.accept(comptime ruleset.is(.@")"));

        return FunctionCall { .name = id.text };
    }

    pub fn acceptExpression(self: *Parser) Error!Expression {
        const state = self.core.saveState();
        errdefer self.core.restoreState(state);

        if (self.acceptFunctionCall()) |call| {
            return Expression { .FunctionCall = try call };
        } else {
            return try self.acceptAddExpression();
        }
    }

    pub fn acceptAddExpression(self: *Parser) Error!Expression {
        const state = self.core.saveState();
        errdefer self.core.restoreState(state);

        const lhs = try self.acceptNumber();
        _ = try self.core.accept(comptime ruleset.is(.@"+"));
        const rhs = try self.acceptNumber();

        return Expression { .Add = .{ .lhs = lhs, .rhs = rhs }};
    }

    // TODO: convert number to rationals
    pub fn acceptNumber(self: *Parser) Error!Number {
        const state = self.core.saveState();
        errdefer self.core.restoreState(state);

        const token = try self.core.accept(comptime ruleset.oneOf(.{
            .number
        }));

        switch (token.type) {
            .number => return token.text,
            else => unreachable
        }
    }

};
