const std = @import("std");
const ptk = @import("parser-toolkit");
const Parser = @import("parser.zig").Parser;
const IntermediateRepresentation = @import("ir.zig");

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
    for (ir) |instruction| {
        std.log.info("{}", .{ instruction });
        switch (instruction) {
            .LoadByte => |lb| registers[lb.target] = lb.value,
            .Add => |add| registers[add.target] = registers[add.lhs] + registers[add.rhs],
            .SetLocal => |set| {
                std.log.info("set local {d} to number {d}", .{ set.local, registers[set.source] });
            },
            .LoadLocal => |set| {
                std.log.info("load from local {d} to register {d}", .{ set.local, set.target });
            },
            .CallFunction => |call| std.log.info("call {s}", .{ call.name })
        }
    }
}
