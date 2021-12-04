const std = @import("std");
const IntermediateRepresentation = @import("ir.zig");

// TODO: rhm will have approximate mode, which runs faster at the expense of using floats instead of Reals
// TODO: resolve() standard function for resolving equations (only on functions with no control flow)
// ex: function sinus(x) -> sin(x)
//     resolve(sinus, "=")  -- return a function that given an expected result b, returns a number a such that f(a) = b
//     resolve(sinus, "=")(1) -- should be equal to π/2

const Value = union(enum) {
    // TODO: UInt32, Int32, etc. types to save on memory
    // TODO: use rationals
    Number: u32,
    String: []const u8
};

pub fn execute(ir: []const IntermediateRepresentation.Instruction) void {
    var registers: [256]Value = undefined;
    
    // TODO: dynamically size locals array
    var locals: [16]Value = undefined;
    for (ir) |instruction| {
        std.log.scoped(.vm).debug("{}", .{ instruction });
        switch (instruction) {
            .LoadByte => |lb| registers[@enumToInt(lb.target)] = .{ .Number = lb.value },
            .LoadString => |ls| registers[@enumToInt(ls.target)] = .{ .String = ls.value },
            .Add => |add| {
                const result = registers[@enumToInt(add.lhs)].Number + registers[@enumToInt(add.rhs)].Number;
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
            .CallFunction => |call| {
                std.log.scoped(.vm).debug("call {s} with {d} arguments ", .{ call.name, call.args_num });
                if (std.mem.eql(u8, call.name, "print")) {
                    const value = registers[@enumToInt(call.args_start)];
                    switch (value) {
                        .Number => std.log.info("{}", .{ value.Number }),
                        .String => std.log.info("{s}", .{ value.String }),
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