// NOTE: Vectors are column-major
//       Matrices are row-major

const std = @import("std");
const cfg = @import("../config.zig");

pub const Float = cfg.Float;
pub const Vec3f = cfg.Vec3f;

pub inline fn length_squared(v: Vec3f) Float {
    const p = v * v;
    return @reduce(.Add, p);
}

pub inline fn length(v: Vec3f) Float {
    return std.math.sqrt(length_squared(v));
}

pub inline fn normalize(v: Vec3f) Vec3f {
    const lsq = length_squared(v);

    return v / @as(Vec3f, @splat(std.math.sqrt(lsq)));
}

pub inline fn dot_product(v1: Vec3f, v2: Vec3f) Float {
    const prod = v1 * v2; // lane wise multiply
    return @reduce(.Add, prod); // return the sum of the lanes
}

// NOTE: Already implemented for homogeneous coordinates
pub inline fn cross_product(a: Vec3f, b: Vec3f) Vec3f {
    const ax = a[0];
    const ay = a[1];
    const az = a[2];

    const bx = b[0];
    const by = b[1];
    const bz = b[2];

    return .{
        ay * bz - az * by,
        az * bx - ax * bz,
        ax * by - ay * bx,
    };
}

pub inline fn add(a: Vec3f, b: Vec3f) Vec3f {
    return .{
        .v = a + b,
    };
}

pub inline fn sub(a: Vec3f, b: Vec3f) Vec3f {
    return .{
        .v = a - b,
    };
}

pub inline fn scale(a: Vec3f, scalar: Float) Vec3f {
    return .{
        .v = a * @as(Vec3f, @splat(scalar)),
    };
}
