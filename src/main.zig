const std = @import("std");
const ptk = @import("parser-toolkit");
const Parser = @import("parser.zig").Parser;
const IntermediateRepresentation = @import("ir.zig");
const vm = @import("vm.zig");

// pub const log_level = .info;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const file = try std.fs.cwd().openFile("hello.rhm", .{});
    defer file.close();

    const text = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(text);
    
    const parsed = try Parser.parse(allocator, text, "hello.rhm");
    defer allocator.free(parsed);

    const ir = try IntermediateRepresentation.encode(allocator, parsed);
    defer allocator.free(ir);

    vm.execute(ir);
}
