const std = @import("std");

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

    /// It means the Real represents the result of multipler + multiple
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
pub const Real = struct {
    multiplier: Multiplier,
    /// Used for things like logarithms and exponentials
    extra: ?*Real = null,
    multiple: Multiple,

    // We only need multiplication (and exponentiation) and addition as for example:
    // 2 / sqrt(π) can be translated to 2 * sqrt(π)⁻¹
    // and π - 1 can be translated to π + (-1)

    pub fn initRational(number: Rational, multiple: Multiple) Real {
        return Real {
            .multiplier = .{ .Rational = number },
            .multiple = multiple
        };
    }

    fn initOne(allocator: Allocator, other: Real) !Real {
        const real = try allocator.create(Real);
        real.* = other;
        return Real {
            .multiplier = .{ .Real = real },
            .multiple = .One
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
        new.* = .{
            .multiplier = a.multiplier,
            .multiple = b.multiple
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

    pub fn pow(self: *Real, exponent: *Real) std.mem.Allocator.Error!void {
        if (self.multiple != .One) {
            const new = try Real.initOne(self.getAllocator(), self.*);
            self.* = new;
        }

        self.extra = exponent;
        self.multiple = .Exponential;
        self.simplify();
    }

    pub fn simplify(self: *Real) void {
        // we're multiplying a real by one, which is redundant
        if (self.multiple == .One and self.multiplier == .Real) {
            const real = self.multiplier.Real.*;
            self.* = real;
        }

        if (self.extra) |extra| {
            extra.simplify();
        }
    }

    fn formatImpl(value: Real, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype, depth: usize) @TypeOf(writer).Error!void {
        const prefix: []const u8 = switch (value.multiple) {
            .Root => "root(",
            .Sqrt => "√(",
            .Log => "log(",
            .Exponential => "(",
            .Addition => "(",
            else => ""
        };
        try writer.print("{s}", .{ prefix });

        if (value.extra) |extra| {
            if (value.multiple != .Exponential) { // handled separately
                try formatImpl(extra.*, fmt, options, writer, depth + 1);
                try writer.print(", ", .{});
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
                if (!rational.p.toConst().eq(bigOne) and !rational.q.toConst().eq(bigOne)) {
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
            .One => " * 1",
            .Pi => "π",
            .EulerNumber => "e",
            .GoldenRatio => "Φ",
            .Root, .Sqrt, .Log, .Exponential, .Addition => ")",
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
