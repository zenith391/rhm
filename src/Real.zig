const std = @import("std");

const Rational = std.math.big.Rational;
const Allocator = *std.mem.Allocator;

/// Enumeration of exact value that are irrational
const Multiple = enum {
    /// If multiple is one, this just means 'multiplier' field
    /// is the actual number.
    One,
    Pi,
    EulerNumber,
    GoldenRatio,

    /// This one is special as it means the Real represents root_extra(multiplier)
    Root,

    /// Represents sqrt(multiplier), it's like with Root multiplier but we save on a Real
    Sqrt,

    /// This one means the Real represents log_extra(multiplier), that is
    /// performs a logarithm of base 'extra' with 'multiplier'.
    Log,

    /// This takes 'multiplier' to the power of 'extra'
    Exponential
};

const Multiplier = union(enum) {
    Real: *Real,
    // TODO: maybe make it a pointer too to save space
    Rational: Rational
};

/// This class can represent exactly any real number
pub const Real = struct {
    multiplier: Multiplier,
    /// Used for things like logarithms and exponentials
    extra: ?*Real = null,
    multiple: Multiple,

    // Constants like 2 / sqrt(π) can be translated into
    // 2 * sqrt(π)⁻¹

    // π + 1 is π * (π+1)/π

    pub fn initRational(number: Rational, multiple: Multiple) Real {
        return Real {
            .multiplier = .{ .Rational = number },
            .multiple = multiple
        };
    }

    pub fn pi(allocator: Allocator) !Real {
        var one = try Rational.init(allocator);
        try one.setInt(1);
        return Real.initRational(one, .Pi);
    }

    pub fn initFloat(allocator: Allocator, number: anytype) !Real {
        var rational = try Rational.init(allocator);
        try rational.setFloat(@TypeOf(number), number);
        return Real.initRational(rational, .One);
    }

    fn getAllocator(self: Real) Allocator {
        switch (self.multiplier) {
            .Real => |real| return real.getAllocator(),
            .Rational => |rational| return rational.p.allocator
        }
    }

    fn getRational(multiplier: *Multiplier) *Rational {
        switch (multiplier.*) {
            .Real => |real| return Real.getRational(&real.multiplier),
            .Rational => |*rational| return rational
        }
    }

    pub fn mul(a: *Real, b: Real) std.mem.Allocator.Error!void {
        var new = try a.getAllocator().create(Real);
        new.multiplier = a.multiplier;
        new.multiple = b.multiple;

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
    }

    pub fn format(value: Real, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        switch (value.multiplier) {
            .Real => |real| {
                try format(real.*, fmt, options, writer);
                try writer.print(" * ", .{});
            },
            .Rational => |rational| {
                if (comptime std.mem.eql(u8, fmt, "d")) {
                    const float = rational.toFloat(f64) catch unreachable;
                    try writer.print("{d} * ", .{ float });
                } else {
                    try writer.print("{}/{} * ", .{ rational.p, rational.q });
                }
            }
        }

        const multiple: []const u8 = switch (value.multiple) {
            .One => "1",
            .Pi => "π",
            .EulerNumber => "e",
            .GoldenRatio => "Φ",
            else => @panic("TODO")
        };
        try writer.print("{s}", .{ multiple });
    }

    pub fn deinit(self: *Real) void {
        switch (self.multiplier) {
            .Real => |real| {
                const allocator = real.getAllocator();
                real.deinit();
                allocator.destroy(real);
            },
            .Rational => |*rational| {
                rational.deinit();
            }
        }
    }

    // TODO: approximate() function, which computes the irrational up to the given number of digits
};

test "simple rationals" {
    const allocator = std.testing.allocator;

    var real = try Real.initFloat(allocator, @as(f64, 123.4));
    defer real.deinit();

    var pi = try Real.pi(allocator);
    defer pi.deinit();

    std.log.err("{d} * {d}", .{ real, pi });

    try real.mul(pi);
    std.log.err("result = {d}", .{ real });

    try real.mul(pi);
    std.log.err("result * pi = {d}", .{ real });
}
