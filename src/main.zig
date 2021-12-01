const std = @import("std");
const ptk = @import("parser-toolkit");
const Parser = @import("parser.zig").Parser;
const IntermediateRepresentation = @import("ir.zig");

// pub const log_level = .info;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;

    const file = try std.fs.cwd().openFile("hello.rhm", .{});
    defer file.close();

    const text = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(text);
    
    const parsed = try Parser.parse(allocator, text);
    defer allocator.free(parsed);

    const ir = try IntermediateRepresentation.encode(allocator, parsed);
    defer allocator.free(ir);

    var registers: [256]u8 = undefined;
    
    // TODO: dynamically size locals array
    var locals: [16]u8 = undefined;
    for (ir) |instruction| {
        std.log.scoped(.vm).debug("{}", .{ instruction });
        switch (instruction) {
            .LoadByte => |lb| registers[@enumToInt(lb.target)] = lb.value,
            .Add => |add| registers[@enumToInt(add.target)] = registers[@enumToInt(add.lhs)]
                + registers[@enumToInt(add.rhs)],
            .SetLocal => |set| {
                std.log.scoped(.vm).debug("set local {d} to number {d}", .{ set.local, registers[@enumToInt(set.source)] });
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
                    std.log.info("{}", .{ value });
                }
            },
            .Move => |move| {
                registers[@enumToInt(move.target)] = registers[@enumToInt(move.source)];
            }
        }
    }
}
