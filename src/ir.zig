const std = @import("std");
const parser = @import("parser.zig").Parser;
const Allocator = *std.mem.Allocator;

const Local = u8;
const Register = u8;

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
        name: []const u8
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
};

pub fn encode(allocator: Allocator, block: parser.Block) ![]const Instruction {
    var state = IrEncodeState.init(allocator);
    errdefer state.instructions.deinit();

    // TODO: use for debug info
    defer state.locals.deinit();

    for (block) |statement| {
        _ = statement;
        switch (statement) {
            .SetLocal => |assign| {
                const valueIdx = try encodeExpression(&state, assign.value);
                defer state.freeRegisters.set(valueIdx);

                const localIdx = (try state.locals.getOrPutValue(assign.name,
                    @intCast(u8, state.locals.count()))).value_ptr.*;
                try state.instructions.append(.{ .SetLocal = .{
                    .local = localIdx,
                    .source = valueIdx
                }});
            },
            .FunctionCall => |call| {
                try state.instructions.append(.{ .CallFunction = .{
                    .name = call.name
                }});
            }
        }
    }

    return state.instructions.toOwnedSlice();
}

const GetFreeRegisterError = error { OutOfRegisters };
fn getFreeRegister(freeRegisters: *RegisterBitSet) GetFreeRegisterError!Register {
    return @intCast(u8, freeRegisters.toggleFirstSet() orelse return error.OutOfRegisters);
}

const ExpressionEncodeError = error {} || GetFreeRegisterError || std.fmt.ParseIntError || std.mem.Allocator.Error;

/// Returns the register containing the expression's value
fn encodeExpression(state: *IrEncodeState, expr: parser.Expression) ExpressionEncodeError!Register {
    defer expr.deinit(state.allocator);
    switch (expr) {
        .Number => |number| {
            const num = try std.fmt.parseUnsigned(u8, number, 10);

            const numberIdx = try getFreeRegister(&state.freeRegisters);
            try state.instructions.append(.{ .LoadByte = .{
                .target = numberIdx,
                .value = num
            }});

            return numberIdx;
        },
        .Add => |addition| {
            const lhsIdx = try encodeExpression(state, addition.lhs.*);
            defer state.freeRegisters.set(lhsIdx);

            const rhsIdx = try encodeExpression(state, addition.rhs.*);
            defer state.freeRegisters.set(rhsIdx);

            const resultIdx = try getFreeRegister(&state.freeRegisters);
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
                .name = call.name
            }});
            unreachable;
        },
        .Local => |local| {
            const resultIdx = try getFreeRegister(&state.freeRegisters);
            try state.instructions.append(.{ .LoadLocal = .{
                .target = resultIdx,
                .local = state.locals.get(local).? // correct use of locals should have been made in a validation phase
            }});

            return resultIdx;
        }
    }
}