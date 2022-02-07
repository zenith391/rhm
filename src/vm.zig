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
    // TODO: UInt32, Int32, etc. types to save on memory
    // TODO: use rationals
    Number: Real,
    // Number: Real
    String: []const u8
};

pub fn execute(allocator: Allocator, ir: []const IntermediateRepresentation.Instruction) !void {
    var registers: [256]Value = undefined;
    
    // TODO: dynamically size locals array
    var locals: [16]Value = undefined;
    for (ir) |instruction| {
        std.log.scoped(.vm).debug("{}", .{ instruction });
        switch (instruction) {
            .LoadByte => |lb| {
                var rational = try Rational.init(allocator);
                try rational.setFloat(f32, @intToFloat(f32, lb.value));
                const real = Real.initRational(rational, .One);

                registers[@enumToInt(lb.target)] = .{ .Number = real };
            },
            .LoadString => |ls| registers[@enumToInt(ls.target)] = .{ .String = ls.value },
            .Add => |add| {
                // const result = registers[@enumToInt(add.lhs)].Number + registers[@enumToInt(add.rhs)].Number;
                var result = registers[@enumToInt(add.lhs)].Number;
                try result.add(registers[@enumToInt(add.rhs)].Number);
                registers[@enumToInt(add.target)] = .{ .Number = result };
            },
            .SetLocal => |set| {
                std.log.scoped(.vm).debug("set local {d} to {d}", .{ set.local, registers[@enumToInt(set.source)] });
                locals[@enumToInt(set.local)] = registers[@enumToInt(set.source)];
            },
            .LoadLocal => |load| {
                std.log.scoped(.vm).debug("load from local {d} to register {d}", .{ load.local, load.target });
                registers[@enumToInt(load.target)] = locals[@enumToInt(load.local)];
            },
            .LoadGlobal => |load| {
                std.log.scoped(.vm).debug("load from global {s} to register {d}", .{ load.global, load.target });
                if (std.mem.eql(u8, load.global, "pi")) {
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
                            .Number => std.log.info("{d}", .{ value.Number }),
                            .String => std.log.info("{s}", .{ value.String }),
                        }
                    }
                } else {
                    std.log.err("no such function {s}", .{ call.name });
                }
            },
            .Move => |move| {
                registers[@enumToInt(move.target)] = registers[@enumToInt(move.source)];
            }
        }
    }
}