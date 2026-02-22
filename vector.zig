// NOTE: Vectors are column-major
//       Matrices are row-major

const std = @import("std");
const cfg = @import("config.zig");

pub const float = cfg.float;
pub const vec3f = cfg.vec3f;

pub const Vec3f = struct {
    v: vec3f,

    pub inline fn length_squared(self: Vec3f) float {
        const p = self.v * self.v;
        return @reduce(.Add, p);
    }

    pub inline fn length(self: Vec3f) float {
        return std.math.sqrt(self.length_squared());
    }

    pub inline fn normalize(self: *Vec3f) void {
        const lsq = self.length_squared();
        if (lsq == 0) return;

        self.v = self.v / @as(vec3f, @splat(std.math.sqrt(lsq)));
    }
};

pub inline fn length_squared(v: vec3f) float {
    const p = v * v;
    return @reduce(.Add, p);
}

pub inline fn length(v: vec3f) float {
    return std.math.sqrt(length_squared(v));
}

pub inline fn normalize(v: vec3f) vec3f {
    const lsq = length_squared(v);

    return v / @as(vec3f, @splat(std.math.sqrt(lsq)));
}

pub inline fn dot_product(v1: vec3f, v2: vec3f) float {
    const prod = v1 * v2; // lane wise multiply
    return @reduce(.Add, prod); // return the sum of the lanes
}

// NOTE: Already implemented for homogeneous coordinates
pub inline fn cross_product(a: vec3f, b: vec3f) vec3f {
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

pub inline fn scale(a: Vec3f, scalar: float) Vec3f {
    return .{
        .v = a * @as(vec3f, @splat(scalar)),
    };
}
