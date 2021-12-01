const std = @import("std");
const parser = @import("parser.zig").Parser;
const Allocator = *std.mem.Allocator;

const Local = enum(u8) { _ };
const Register = enum(u8) {
    _,

    pub fn id(n: u8) Register {
        return @intToEnum(Register, n);
    }
};

// Using an union makes each instruction take more memory but avoid loading times.
pub const Instruction = union(enum) {
    /// Instruction used to load small (0-255) integers
    LoadByte: struct {
        target: Register,
        value: u8
    },
    Add: struct {
        target: Register,
        lhs: Register,
        rhs: Register
    },
    LoadLocal: struct {
        target: Register,
        local: Local
    },
    SetLocal: struct {
        local: Local,
        source: Register
    },
    CallFunction: struct {
        name: []const u8,
        args_start: Register,
        args_num: u8
    },
    /// Move the content of one register to another
    Move: struct {
        source: Register,
        target: Register
    }
};

const max_register_value = std.math.powi(usize, 2, @bitSizeOf(Register)) catch unreachable;
const RegisterBitSet = std.StaticBitSet(max_register_value);

const IrEncodeState = struct {
    instructions: std.ArrayList(Instruction),
    locals: std.StringHashMap(Local),
    freeRegisters: RegisterBitSet,
    allocator: Allocator,
    
    pub fn init(allocator: Allocator) IrEncodeState {
        return IrEncodeState {
            .instructions = std.ArrayList(Instruction).init(allocator),
            .locals = std.StringHashMap(Local).init(allocator),
            .freeRegisters = RegisterBitSet.initFull(),
            .allocator = allocator
        };
    }

    pub const GetFreeRegisterError = error { OutOfRegisters };
    fn getFreeRegister(self: *IrEncodeState) GetFreeRegisterError!Register {
        return @intToEnum(Register, @intCast(u8,
            self.freeRegisters.toggleFirstSet() orelse return error.OutOfRegisters));
    }

    fn peekFreeRegister(self: *IrEncodeState) GetFreeRegisterError!Register {
        return @intToEnum(Register, @intCast(u8,
            self.freeRegisters.findFirstSet() orelse return error.OutOfRegisters));
    }

    fn freeRegister(self: *IrEncodeState, register: Register) void {
        self.freeRegisters.set(@enumToInt(register));
    }

};

pub fn encode(allocator: Allocator, block: parser.Block) ![]const Instruction {
    var state = IrEncodeState.init(allocator);
    errdefer state.instructions.deinit();

    // TODO: use for debug info
    defer state.locals.deinit();

    for (block) |statement| {
        defer statement.deinit(allocator);
        switch (statement) {
            .SetLocal => |assign| {
                const valueIdx = try encodeExpression(&state, assign.value);
                defer state.freeRegister(valueIdx);

                const localIdx = (try state.locals.getOrPutValue(assign.name,
                    @intToEnum(Local, @intCast(u8, state.locals.count())))).value_ptr.*;
                try state.instructions.append(.{ .SetLocal = .{
                    .local = localIdx,
                    .source = valueIdx
                }});
            },
            .FunctionCall => |call| {
                var start = Register.id(0);
                if (call.args.len > 0) {
                    for (call.args) |arg, i| {
                        const idx = try encodeExpression(&state, arg);
                        // set start to the location of the first argument
                        if (i == 0) {
                            start = idx;
                        }

                        // expected register
                        const expected = @intToEnum(Register, @enumToInt(start) + @intCast(u8, i));

                        if (idx != expected) {
                            try state.instructions.append(.{ .Move = .{
                                .source = idx,
                                .target = expected
                            }});
                        }
                    }
                }
                try state.instructions.append(.{ .CallFunction = .{
                    .name = call.name,
                    .args_start = start,
                    .args_num = @intCast(u8, call.args.len)
                }});
            }
        }
    }

    return state.instructions.toOwnedSlice();
}

const ExpressionEncodeError = error {} || IrEncodeState.GetFreeRegisterError ||
    std.fmt.ParseIntError || std.mem.Allocator.Error;

/// Returns the register containing the expression's value
fn encodeExpression(state: *IrEncodeState, expr: parser.Expression) ExpressionEncodeError!Register {
    defer expr.deinit(state.allocator);
    switch (expr) {
        .Number => |number| {
            const num = try std.fmt.parseUnsigned(u8, number, 10);

            const numberIdx = try state.getFreeRegister();
            try state.instructions.append(.{ .LoadByte = .{
                .target = numberIdx,
                .value = num
            }});

            return numberIdx;
        },
        .Add => |addition| {
            const lhsIdx = try encodeExpression(state, addition.lhs.*);
            defer state.freeRegister(lhsIdx);

            const rhsIdx = try encodeExpression(state, addition.rhs.*);
            defer state.freeRegister(rhsIdx);

            const resultIdx = try state.getFreeRegister();
            try state.instructions.append(.{ .Add = .{
                .target = resultIdx,
                .lhs = lhsIdx,
                .rhs = rhsIdx
            }});
            return resultIdx;
        },
        .FunctionCall => |call| {
            // TODO: get result
            try state.instructions.append(.{ .CallFunction = .{
                .name = call.name,
                .args_start = Register.id(0),
                .args_num = 0
            }});
            unreachable;
        },
        .Local => |local| {
            const resultIdx = try state.getFreeRegister();
            try state.instructions.append(.{ .LoadLocal = .{
                .target = resultIdx,
                .local = state.locals.get(local).? // correct use of locals should have been made in a validation phase
            }});

            return resultIdx;
        }
    }
}