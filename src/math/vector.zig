const std = @import("std");
const types = @import("../types.zig");

const F3 = types.F3;

pub inline fn length_squared(v: F3) f32 {
    const p = v * v;
    return @reduce(.Add, p);
}

pub inline fn length(v: F3) f32 {
    return std.math.sqrt(length_squared(v));
}

pub inline fn normalize(v: F3) F3 {
    const lsq = length_squared(v);

    return v / @as(F3, @splat(std.math.sqrt(lsq)));
}

pub inline fn dot_product(v1: F3, v2: F3) f32 {
    const prod = v1 * v2;
    return @reduce(.Add, prod);
}

pub inline fn cross_product(a: F3, b: F3) F3 {
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

pub inline fn scale(a: F3, scalar: f32) F3 {
    return a * @as(F3, @splat(scalar));
}
