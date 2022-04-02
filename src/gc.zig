const std = @import("std");
const global_gc = &@import("main.zig").global_gc;
const Allocator = std.mem.Allocator;

const Collectible = struct {
    freeFn: fn() void,
};

pub const GarbageCollector = struct {
    child_allocator: Allocator,
    collectibles: std.ArrayList(Collectible),

    pub fn init(child_allocator: Allocator) GarbageCollector {
        return GarbageCollector {
            .child_allocator = child_allocator,
            .collectibles = std.ArrayList(Collectible).init(child_allocator)
        };
    }

    pub fn createCollectible(self: *GarbageCollector, comptime T: type) !*T {
        const ptr = try self.child_allocator.create(T);

        return ptr;
    }

    pub fn create(self: *GarbageCollector, comptime T: type) !*T {
        return try self.child_allocator.create(T);
    }

};

/// A reference counter for objects.
/// This assumes T has a deinit() function and that the reference counter
/// is placed in an `rc` field.
pub fn ReferenceCounter(comptime T: type) type {
    return struct {
        count: u32 = 1,

        const Self = @This();

        pub fn reference(self: *Self) void {
            if (std.debug.runtime_safety and self.count == 0) {
                @panic("Cannot reference an object that has already been dereferenced");
            }
            _ = @atomicRmw(u32, &self.count, .Add, 1, .SeqCst);
            std.log.info("ref now rc = {}", .{ self.count });
        }

        pub fn dereference(self: *Self) void {
            if (std.debug.runtime_safety and self.count == 0) {
                @panic("Cannot dereference an object with no references");
            }
            _ = @atomicRmw(u32, &self.count, .Sub, 1, .SeqCst);
            std.log.info("deref now rc = {}", .{ self.count });
            if (self.count == 0) {
                // TODO: defer the freeing using GarbageCollector
                const selfT = @fieldParentPtr(T, "rc", self);
                selfT.deinit(global_gc.child_allocator);
            }
        }

        /// The object has had its deinit() function explicitely called,
        /// so disable reference counting
        pub fn deinit(self: *Self) void {
            @atomicStore(u32, &self.count, 0, .SeqCst);
        }
    };
}
