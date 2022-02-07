const std = @import("std");
const ptk = @import("parser-toolkit");
const matchers = ptk.matchers;

const Allocator = std.mem.Allocator;

pub const Parser = struct {
    core: ParserCore,
    source: []const u8,
    allocator: Allocator,

    const TokenType = enum {
        number,
        identifier,
        whitespace,
        linefeed,
        double_quoted_string,
        @"(",
        @")",
        @",",
        @"+",
        @";",
        define,
        char,
    };

    const Pattern = ptk.Pattern(TokenType);

    const Tokenizer = ptk.Tokenizer(TokenType, &[_]Pattern{
        Pattern.create(.number, matchers.sequenceOf(.{ matchers.decimalNumber })),
        Pattern.create(.number, matchers.sequenceOf(.{ matchers.decimalNumber, matchers.literal("."), matchers.decimalNumber })),
        Pattern.create(.identifier, matchers.identifier),
        Pattern.create(.linefeed, matchers.linefeed),
        Pattern.create(.whitespace, matchers.whitespace),
        Pattern.create(.@"+", matchers.literal("+")),
        Pattern.create(.@"(", matchers.literal("(")),
        Pattern.create(.@")", matchers.literal(")")),
        Pattern.create(.@",", matchers.literal(",")),
        Pattern.create(.@";", matchers.literal(";")),
        Pattern.create(.define, matchers.literal("=")),
        Pattern.create(.double_quoted_string, matchers.sequenceOf(.{
            matchers.literal("\""),
            matchers.takeNoneOf("\"\r\n"),
            matchers.literal("\""),
        })),
    });

    const ParserCore = ptk.ParserCore(Tokenizer, .{ .whitespace });
    const ruleset = ptk.RuleSet(TokenType);

    pub fn parse(allocator: Allocator, block: []const u8, fileName: ?[]const u8) !Block {
        var tokenizer = Tokenizer.init(block, fileName);

        var parser = Parser {
            .core = ParserCore.init(&tokenizer),
            .source = block,
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
        args: []Expression
    };

    pub const Statement = union(enum) {
        SetLocal: struct {
            name: []const u8,
            value: Expression
        },
        FunctionCall: FunctionCall,

        pub fn deinit(self: *const Statement, allocator: Allocator) void {
            switch (self.*) {
                .FunctionCall => |stat| {
                    // assume function's arguments were free before
                    allocator.free(stat.args);
                },
                else => {}
            }
        }

        pub fn deinitAll(self: *const Statement, allocator: Allocator) void {
            switch (self.*) {
                .FunctionCall => |stat| {
                    for (stat.args) |*arg| arg.deinit(allocator);
                },
                else => {}
            }
            self.deinit(allocator);
        }
    };

    pub const Number = std.math.big.Rational;
    pub const Block = []Statement;

    pub const Expression = union(enum) {
        // TODO: pointers to expression instead of number
        Add: struct { lhs: *Expression, rhs: *Expression },
        FunctionCall: FunctionCall,
        Number: Number,
        Local: []const u8,
        StringLiteral: []const u8,

        pub fn deinit(self: *Expression, allocator: Allocator) void {
            switch (self.*) {
                .Add => |expr| {
                    //expr.lhs.deinit(allocator);
                    allocator.destroy(expr.lhs);

                    //expr.rhs.deinit(allocator);
                    allocator.destroy(expr.rhs);
                },
                .FunctionCall => |expr| {
                    for (expr.args) |*arg| arg.deinit(allocator);
                    allocator.free(expr.args);
                },
                .Number => |*number| {
                    number.deinit();
                },
                else => {}
            }
        }
    };

    pub fn acceptBlock(self: *Parser) Error!Block {
        const state = self.core.saveState();
        errdefer self.core.restoreState(state);

        var statements = std.ArrayList(Statement).init(self.allocator);
        errdefer {
            for (statements.items) |stat| stat.deinitAll(self.allocator);
            statements.deinit();
        }

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

        var arguments = std.ArrayList(Expression).init(self.allocator);
        errdefer {
            for (arguments.items) |*arg| arg.deinit(self.allocator);
            arguments.deinit();
        }

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
            try arguments.append(arg);

            first = false;
        }

        _ = try self.core.accept(comptime ruleset.is(.@")"));

        return FunctionCall { .name = id.text, .args = arguments.toOwnedSlice() };
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

        const lhs = try self.acceptVarExpression();
        
        if (self.core.accept(comptime ruleset.is(.@"+"))) |_| {
            const rhs = try self.acceptVarExpression();
            const lhsDupe = try self.allocator.create(Expression);
            errdefer self.allocator.destroy(lhsDupe);
            lhsDupe.* = lhs;

            const rhsDupe = try self.allocator.create(Expression);
            errdefer self.allocator.destroy(rhsDupe);
            rhsDupe.* = rhs;
            return Expression { .Add = .{
                .lhs = lhsDupe,
                .rhs = rhsDupe
            }};
        } else |_| {
            return lhs;
        }
    }

    pub fn acceptVarExpression(self: *Parser) Error!Expression {
        const state = self.core.saveState();
        errdefer self.core.restoreState(state);

        if (self.core.accept(comptime ruleset.is(.identifier))) |token| {
            return Expression { .Local = token.text };
        } else |_| {
            if (self.acceptNumber()) |number| {
                return Expression { .Number = number };
            } else |_| {
                return Expression { .StringLiteral = try self.acceptStringLiteral() };
            }
        }
    }

    pub fn acceptStringLiteral(self: *Parser) Error![]const u8 {
        const state = self.core.saveState();
        errdefer self.core.restoreState(state);

        const token = try self.core.accept(comptime ruleset.is(.double_quoted_string));
        const literal = token.text[1..token.text.len-1];
        return literal;
    }

    // TODO: convert number to rationals
    pub fn acceptNumber(self: *Parser) Error!Number {
        const state = self.core.saveState();
        errdefer self.core.restoreState(state);

        const token = try self.core.accept(comptime ruleset.is(.number));
        var rational = try Number.init(self.allocator);
        rational.setFloatString(token.text) catch unreachable;
        return rational;
    }

};
