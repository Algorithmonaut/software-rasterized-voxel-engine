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

pub inline fn dot_product(v1: Vec3f, v2: Vec3f) float {
    const prod = v1.v * v2.v; // lane wise multiply
    return @reduce(.Add, prod); // return the sum of the lanes
}

// NOTE: Already implemented for homogeneous coordinates
pub inline fn cross_product(a: Vec3f, b: Vec3f) Vec3f {
    // Computes (a.y, a.z, a.x) * (b.z, b.x, b.y) - (a.z, a.x, a.y) * (b.y, b.z, b.x)

    const a_yzx = @shuffle(f32, a, undefined, [4]i32{ 1, 2, 0, 3 });
    const b_zxy = @shuffle(f32, b, undefined, [4]i32{ 2, 0, 1, 3 });

    const a_zxy = @shuffle(f32, a, undefined, [4]i32{ 2, 0, 1, 3 });
    const b_yzx = @shuffle(f32, b, undefined, [4]i32{ 1, 2, 0, 3 });

    const c = a_yzx * b_zxy - a_zxy * b_yzx;

    return .{
        .v = c,
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
