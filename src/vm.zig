const std = @import("std");
const Rational = std.math.big.Rational;
const Allocator = std.mem.Allocator;
const Real = @import("Real.zig").Real;
const IntermediateRepresentation = @import("ir.zig");

// TODO: rhm will have approximate mode, which runs faster at the expense of using floats instead of Reals
// TODO: resolve() standard function for resolving equations (only on functions with no control flow)
// ex: function sinus(x) -> sin(x)
//     resolve(sinus, "=")  -- return a function that given an expected result b, returns a number a such that f(a) = b
//     resolve(sinus, "=")(1) -- should be equal to π/2

const Value = union(enum) {
    None: void,
    // TODO: UInt32, Int32, etc. types to save on memory
    // TODO: use rationals
    Number: *Real,
    // Number: Real
    String: []const u8,

    pub fn clone(self: *Value, allocator: Allocator) !Value {
        switch (self.*) {
            .Number => |object| {
                return Value { .Number = try object.clone(allocator) };
            },
            .String => std.debug.todo("clone strings"),
            .None => unreachable,
        }
    }

    pub fn reference(self: *Value) void {
        switch (self.*) {
            .Number => |object| {
                object.rc.reference();
            },
            else => {}
        }
    }

    pub fn dereference(self: *Value) void {
        switch (self.*) {
            .Number => |object| {
                object.rc.dereference();
            },
            else => {}
        }
    }
};

pub fn execute(allocator: Allocator, ir: []const IntermediateRepresentation.Instruction) !void {
    var registers: [256]Value = [_]Value{ .None } ** 256;
    
    // TODO: dynamically size locals array
    var locals: [16]Value = [_]Value{ .None } ** 16;
    for (ir) |instruction| {
        std.log.scoped(.vm).debug("{}", .{ instruction });
        switch (instruction) {
            .LoadByte => |lb| {
                const real = try Real.initFloat(allocator, @intToFloat(f32, lb.value));

                // Dereference old value
                const registerId = @enumToInt(lb.target);
                registers[registerId].dereference();

                registers[@enumToInt(lb.target)] = .{ .Number = real };
            },
            .LoadString => |ls| {
                // Dereference old value
                const registerId = @enumToInt(ls.target);
                registers[registerId].dereference();

                registers[@enumToInt(ls.target)] = .{ .String = ls.value };
            },
            .Add => |add| {
                var result = try registers[@enumToInt(add.lhs)].Number.clone(allocator);
                try result.add(allocator, registers[@enumToInt(add.rhs)].Number);

                // Dereference old value
                const registerId = @enumToInt(add.target);
                registers[registerId].dereference();

                registers[@enumToInt(add.target)] = .{ .Number = result };
            },
            .SetLocal => |set| {
                std.log.scoped(.vm).debug("set local {d} to {d}", .{ set.local, registers[@enumToInt(set.source)] });
                const localId = @enumToInt(set.local);

                // If there was already a local there, de-reference it
                locals[localId].dereference();

                locals[localId] = try registers[@enumToInt(set.source)].clone(allocator);
            },
            .LoadLocal => |load| {
                std.log.scoped(.vm).debug("load from local {d} to register {d} = {d}", .{ load.local, load.target, locals[@enumToInt(load.local)] });

                // Dereference old value
                const registerId = @enumToInt(load.target);
                registers[registerId].dereference();

                registers[registerId] = try locals[@enumToInt(load.local)].clone(allocator);
            },
            .LoadGlobal => |load| {
                std.log.scoped(.vm).debug("load from global {s} to register {d}", .{ load.global, load.target });
                if (std.mem.eql(u8, load.global, "pi")) {
                    // Dereference old value
                    const registerId = @enumToInt(load.target);
                    registers[registerId].dereference();

                    registers[@enumToInt(load.target)] = .{
                        .Number = try Real.pi(allocator)
                    };
                } else {
                    @panic("TODO");
                }
            },
            .CallFunction => |call| {
                std.log.scoped(.vm).debug("call {s} with {d} arguments ", .{ call.name, call.args_num });
                if (std.mem.eql(u8, call.name, "print")) {
                    var i: u8 = 0;
                    while (i < call.args_num) : (i += 1) {
                        const value = registers[@enumToInt(call.args_start) + i];
                        switch (value) {
                            .None => @panic("'None' value cannot be used by a program"),
                            .Number => std.log.info("{d}", .{ value.Number }),
                            .String => std.log.info("{s}", .{ value.String }),
                        }
                    }
                } else {
                    std.log.err("no such function {s}", .{ call.name });
                    break;
                }
            },
            .Move => |move| {
                // Dereference old value
                const registerId = @enumToInt(move.target);
                registers[registerId].dereference();

                registers[@enumToInt(move.target)] = try registers[@enumToInt(move.source)].clone(allocator);
            }
        }
    }

    for (locals) |*local, idx| {
        if (local.* != .None) std.log.debug("deinit local {d}", .{ idx });
        local.dereference();
    }
    for (registers) |*register, idx| {
        if (register.* != .None) std.log.debug("deinit register {d}", .{ idx });
        register.dereference();
    }
}