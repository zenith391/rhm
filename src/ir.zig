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

pub fn encode(allocator: Allocator, block: parser.Block) ![]const Instruction {
    var instructions = std.ArrayList(Instruction).init(allocator);
    errdefer instructions.deinit();

    // TODO: use for debug info
    var locals = std.StringHashMap(Local).init(allocator);
    defer locals.deinit();

    // TODO: pre-compute the max number of used registers for the bit set size
    var freeRegisters = RegisterBitSet.initFull();
    _ = freeRegisters;

    for (block) |statement| {
        _ = statement;
        switch (statement) {
            .SetLocal => |assign| {
                const valueIdx = try encodeExpression(&instructions, &freeRegisters, assign.value);
                defer freeRegisters.set(valueIdx);

                const localIdx = (try locals.getOrPutValue(assign.name, @intCast(u8, locals.count()))).value_ptr.*;
                try instructions.append(.{ .SetLocal = .{
                    .local = localIdx,
                    .source = valueIdx
                }});
            },
            .FunctionCall => |call| {
                try instructions.append(.{ .CallFunction = .{
                    .name = call.name
                }});
            }
        }
    }

    return instructions.toOwnedSlice();
}

fn getFreeRegister(freeRegisters: *RegisterBitSet) !Register {
    return @intCast(u8, freeRegisters.toggleFirstSet() orelse return error.OutOfRegisters);
}

/// Returns the register containing the expression's value
fn encodeExpression(instructions: *std.ArrayList(Instruction), freeRegisters: *RegisterBitSet, expr: parser.Expression) !Register {
    _ = freeRegisters;
    switch (expr) {
        .Add => |addition| {
            const lhs = try std.fmt.parseUnsigned(u8, addition.lhs, 10);
            const rhs = try std.fmt.parseUnsigned(u8, addition.rhs, 10);

            const lhsIdx = try getFreeRegister(freeRegisters);
            defer freeRegisters.set(lhsIdx);
            try instructions.append(.{ .LoadByte = .{
                .target = lhsIdx,
                .value = lhs
            }});

            const rhsIdx = try getFreeRegister(freeRegisters);
            defer freeRegisters.set(rhsIdx);
            try instructions.append(.{ .LoadByte = .{
                .target = rhsIdx,
                .value = rhs
            }});

            const resultIdx = try getFreeRegister(freeRegisters);
            try instructions.append(.{ .Add = .{
                .target = resultIdx,
                .lhs = 0,
                .rhs = 1
            }});
            return resultIdx;
        },
        else => unreachable
    }
}