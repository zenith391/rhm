const std = @import("std");
const gc = @import("gc.zig");

const Rational = std.math.big.Rational;
const Allocator = std.mem.Allocator;

// TODO: maybe something that allows plugging your own irrational numbers as Multiple:
// it could be defined with a representation (e.g. π) and a function to approximate the result

/// Enumeration of exact value that are irrational
const Multiple = enum {
    /// If multiple is one, this just means 'multiplier' field
    /// is the actual number.
    One,

    /// This one is special as it means the Real represents root_extra(multiplier)
    Root,

    /// Represents sqrt(multiplier), it's like with Root multiplier but we save on a Real
    Sqrt,

    /// This one means the Real represents log_extra(multiplier), that is
    /// performs a logarithm of base 'extra' with 'multiplier'.
    Log,

    /// This takes 'multiplier' to the power of 'extra'
    Exponential,

    /// It means the Real represents the result of multipler + extra
    Addition,

    // Actual irrational numbers
    Pi,
    EulerNumber,
    GoldenRatio,
};

const Multiplier = union(enum) {
    Real: *Real,
    // TODO: maybe make it a pointer too to save space
    Rational: Rational,

    pub fn isOne(self: Multiplier) bool {
        var one = Rational.init(std.heap.page_allocator) catch unreachable;
        defer one.deinit();
        one.setInt(1) catch unreachable;

        return switch (self) {
            .Real => |real| real.multiple == .One and real.multiplier.isOne(),
            .Rational => |rational| (rational.order(one) catch unreachable) == .eq
        };
    }
};

pub const bigOne = std.math.big.int.Const { .limbs = &.{1}, .positive = true };

/// This class can represent exactly any real number
/// Note that it uses reference counting for memory management
/// and so reals are passed as pointers only.
/// Also note that the API of this interface is unmanged, that is
/// you must always provide the allocator which MUST be the same
/// during all of the real's lifetime.
pub const Real = struct {
    multiplier: Multiplier,
    /// Used for things like logarithms and exponentials
    extra: ?*Real = null,
    multiple: Multiple,
    rc: gc.ReferenceCounter(Real) = .{},

    // We only need multiplication (and exponentiation) and addition as for example:
    // 2 / sqrt(π) can be translated to 2 * sqrt(π)⁻¹
    // and π - 1 can be translated to π + (-1)
    pub fn initRational(allocator: Allocator, number: Rational, multiple: Multiple) !*Real {
        const real = try allocator.create(Real);
        real.* = Real {
            .multiplier = .{ .Rational = number },
            .multiple = multiple,
        };
        return real;
    }

    fn initOne(allocator: Allocator, other: *Real) !*Real {
        const real = try allocator.create(Real);
        real.* = Real {
            .multiplier = .{ .Real = other },
            .multiple = .One,
        };
        return real;
    }

    pub fn pi(allocator: Allocator) !*Real {
        var one = try Rational.init(allocator);
        try one.setInt(1);
        return try Real.initRational(allocator, one, .Pi);
    }

    pub fn initFloat(allocator: Allocator, number: anytype) !*Real {
        var rational = try Rational.init(allocator);
        try rational.setFloat(@TypeOf(number), number);
        return try Real.initRational(allocator, rational, .One);
    }

    fn getRational(multiplier: *Multiplier) *Rational {
        switch (multiplier.*) {
            .Real => |real| return Real.getRational(&real.multiplier),
            .Rational => |*rational| return rational
        }
    }

    pub fn mul(a: *Real, allocator: Allocator, b: *const Real) std.mem.Allocator.Error!void {
        var new = allocator.create(Real);
        new.* = .{
            .multiplier = a.multiplier,
            .multiple = b.multiple,
        };

        switch (b.multiplier) {
            .Rational => |rational| {
                const second = getRational(&new.multiplier);
                try second.mul(rational, second.*);
            },
            .Real => |real| {
                try new.mul(real.*);
            }
        }

        a.multiplier = .{ .Real = new };
        a.simplify();
    }

    pub fn pow(self: *Real, allocator: Allocator, exponent: *Real) std.mem.Allocator.Error!void {
        if (self.multiple != .One) {
            const new = try Real.initOne(allocator, self.*);
            self.* = new;
        }

        self.extra = exponent;
        self.multiple = .Exponential;
        self.simplify();
    }

    pub fn add(a: *Real, allocator: Allocator, b: *const Real) std.mem.Allocator.Error!void {
        var newA = try a.clone(allocator);
        newA.simplify(allocator);

        var newB = try b.clone(allocator);
        newB.simplify(allocator);

        const rc = a.rc;
        a.* = .{
            .multiplier = .{ .Real = newA },
            .extra = newB,
            .multiple = .Addition,
            .rc = rc,
        };
        a.simplify(allocator);
    }

    pub fn simplify(self: *Real, allocator: Allocator) void {
        // we're multiplying a real by one, which is redundant
        if (self.multiple == .One and self.multiplier == .Real) {
            const real = self.multiplier.Real;
            self.* = real.*;
            allocator.destroy(real); // extra and multiplier don't need deinit
        }

        // We check our multiplier
        // If it is a rational that is a multiple of one
        // That means we can simplify the multiplier by using
        // .{ .Rational = ... }
        if (self.multiplier == .Real and self.multiplier.Real.multiple == .One
            and self.multiplier.Real.multiplier == .Rational) {
            const rational = self.multiplier.Real.multiplier.Rational;
            var newRational = Rational.init(allocator) catch unreachable;
            newRational.copyRatio(rational.p, rational.q) catch unreachable;

            self.multiplier.Real.rc.dereference();
            self.multiplier = .{ .Rational = newRational };
        }

        if (self.extra) |extra| {
            std.log.info("extra: {*}", .{ extra });
            extra.simplify(allocator);
        }
        
        if (self.multiple == .Addition) {
            const extra = self.extra.?;
            if (self.multiplier == .Rational and extra.multiple == .One) {
                switch (extra.multiplier) {
                    .Rational => |*rational| {
                        rational.add(rational.*, self.multiplier.Rational) catch unreachable;
                        self.extra = null;
                        self.selfDeinit();
                        self.* = extra.*;
                        allocator.destroy(extra);
                    },
                    .Real => |real| {
                        _ = real;
                        // TODO: try real.add(self.multiplier);
                    }
                }
            }
        }
    }

    pub fn clone(self: *const Real, allocator: Allocator) std.mem.Allocator.Error!*Real {
        if (std.debug.runtime_safety and self.rc.count == 0) {
            @panic("Cannot clone an object with no references");
        }
        var new = try allocator.create(Real);
        new.* = self.*;
        new.rc.count = 1;
        switch (new.multiplier) {
            .Real => |real| {
                new.multiplier = .{ .Real = try real.clone(allocator) };
            },
            .Rational => |rational| {
                var newRational = try Rational.init(allocator);
                try newRational.copyRatio(rational.p, rational.q);
                new.multiplier = .{ .Rational = newRational };
            }
        }
        if (new.extra) |extra| {
            new.extra = try extra.clone(allocator);
        }
        return new;
    }

    fn formatImpl(value: Real, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype, depth: usize) @TypeOf(writer).Error!void {
        const prefix: []const u8 = switch (value.multiple) {
            .Root => "root(",
            .Sqrt => "√(",
            .Log => "log(",
            .Exponential => "(",
            .Addition => "((",
            else => ""
        };
        try writer.print("{s}", .{ prefix });

        if (value.extra) |extra| {
            if (value.multiple != .Exponential) { // handled separately
                try formatImpl(extra.*, fmt, options, writer, depth + 1);
                if (value.multiple == .Addition) {
                    try writer.print(") + (", .{});
                } else {
                    try writer.print(", ", .{});
                }
            }
        }

        switch (value.multiplier) {
            .Real => |real| {
                try formatImpl(real.*, fmt, options, writer, depth + 1);
                if (depth > 0) {
                    if (value.multiple == .Addition) {
                        try writer.writeAll(" + ");
                    } else {
                        try writer.writeAll(" * ");
                    }
                }
            },
            .Rational => |rational| {
                // avoid useless things like 1 * number
                if (!(rational.p.toConst().eq(bigOne) and rational.q.toConst().eq(bigOne)) or true) {
                    if (comptime std.mem.eql(u8, fmt, "d")) {
                        const float = rational.toFloat(f64) catch unreachable;
                        try writer.print("{d}", .{ float });
                    } else {
                        try writer.print("{}/{}", .{ rational.p, rational.q });
                    }
                    if (depth > 0) {
                        if (value.multiple == .Addition) {
                            try writer.writeAll(" + ");
                        } else {
                            try writer.writeAll(" * ");
                        }
                    }
                }
            }
        }

        const multiple: []const u8 = switch (value.multiple) {
            //.One => " * 1",
            .One => "", // * 1 is used purely for debug reasons
            .Pi => "π",
            .EulerNumber => "e",
            .GoldenRatio => "Φ",
            .Addition => "))",
            .Root, .Sqrt, .Log, .Exponential => ")",
        };
        try writer.print("{s}", .{ multiple });
        if (value.multiple == .Exponential) {
            try writer.print(" ^ (", .{});
            try formatImpl(value.extra.?.*, fmt, options, writer, 0);
            try writer.print(")", .{});
        }
    }

    pub fn format(value: Real, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try formatImpl(value, fmt, options, writer, 0);
    }

    pub fn deinit(self: *Real, allocator: Allocator) void {
        std.log.info("deinit rational {*}: rc={d} value={0}", .{ self, self.rc.count });
        //std.debug.dumpCurrentStackTrace(null);
        self.rc.deinit();
        self.selfDeinit();
        allocator.destroy(self);
    }

    fn selfDeinit(self: *Real) void {
        switch (self.multiplier) {
            .Real => |real| {
                real.rc.dereference();
            },
            .Rational => |*rational| {
                rational.deinit();
            }
        }
        if (self.extra) |extra| {
            std.log.info("deref extra", .{});
            extra.rc.dereference();
        }
    }

    // TODO: approximate() function, which computes the irrational up to around the given number of digits
};

test "simple rationals" {
    const allocator = std.testing.allocator;

    var real = try Real.initFloat(allocator, @as(f64, 123.4));
    defer real.deinit();

    var pi = try Real.pi(allocator);
    defer pi.deinit();

    std.log.err("{d}, multiplied by {d}", .{ real, pi });

    try real.mul(pi);
    std.log.err("result = {d}", .{ real });

    try real.mul(pi);
    std.log.err("result * pi = {d}", .{ real });

    try real.pow(&pi);
    std.log.err("(result) ^ pi = {}", .{ real });
}

test "addition" {
    const allocator = std.testing.allocator;

    var real = try Real.initFloat(allocator, @as(f64, 1.23456789));
    defer real.deinit();

    var pi = try Real.pi(allocator);
    defer pi.deinit();

    std.log.err("{d} + {d}", .{ real, pi });

    try real.add(pi);
    std.log.err("result = {d}", .{ real });
}