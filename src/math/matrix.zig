const std = @import("std");
const vec = @import("vector.zig");
const types = @import("../types.zig");

const F3 = types.F3;
const F4 = types.F4;
const Camera = @import("../game/Camera.zig").Camera;

pub const Mat4f = struct {
    r: [4]F4,

    pub inline fn identity() Mat4f {
        return .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        };
    }

    pub inline fn mulVec(self: Mat4f, v: F4) F4 {
        return .{
            @reduce(.Add, self.r[0] * v),
            @reduce(.Add, self.r[1] * v),
            @reduce(.Add, self.r[2] * v),
            @reduce(.Add, self.r[3] * v),
        };
    }

    inline fn rowTimesCol(row: F4, col0: F4, col1: F4, col2: F4, col3: F4) F4 {
        return .{
            @reduce(.Add, row * col0),
            @reduce(.Add, row * col1),
            @reduce(.Add, row * col2),
            @reduce(.Add, row * col3),
        };
    }

    // Matrix multiply: out = self * b
    pub inline fn mul(self: Mat4f, b: Mat4f) Mat4f {
        // Build columns of b
        const c0: F4 = .{ b.r[0][0], b.r[1][0], b.r[2][0], b.r[3][0] };
        const c1: F4 = .{ b.r[0][1], b.r[1][1], b.r[2][1], b.r[3][1] };
        const c2: F4 = .{ b.r[0][2], b.r[1][2], b.r[2][2], b.r[3][2] };
        const c3: F4 = .{ b.r[0][3], b.r[1][3], b.r[2][3], b.r[3][3] };

        return .{ .r = .{
            rowTimesCol(self.r[0], c0, c1, c2, c3),
            rowTimesCol(self.r[1], c0, c1, c2, c3),
            rowTimesCol(self.r[2], c0, c1, c2, c3),
            rowTimesCol(self.r[3], c0, c1, c2, c3),
        } };
    }
};

pub fn createProjMat(
    fov: f32,
    far: f32,
    fb_width: usize,
    fb_height: usize,
    near: f32,
) Mat4f {
    const w: f32 = @floatFromInt(fb_width);
    const h: f32 = @floatFromInt(fb_height);
    const aspect: f32 = w / h;

    const y_scale: f32 = 1.0 / @tan(fov * std.math.pi / 360.0);
    const x_scale: f32 = y_scale / aspect;

    return .{ .r = .{
        .{ x_scale, 0, 0, 0 },
        .{ 0, y_scale, 0, 0 },
        .{ 0, 0, (-far) / (far - near), -(far * near) / (far - near) },
        .{ 0, 0, -1, 0 },
    } };
}

pub inline fn createViewMat(from: F3, to: F3) Mat4f {
    const world_up = F3{ 0, 1, 0 };

    const f = vec.normalize(to - from); // forward
    const s = vec.normalize(vec.cross_product(f, world_up)); // right

    const u = vec.cross_product(s, f); // up (already orthogonal if r, f are)

    // Right-handed view: camera forward is -Z, so use -f in the basis
    return .{ .r = .{
        .{ s[0], s[1], s[2], -vec.dot_product(s, from) },
        .{ u[0], u[1], u[2], -vec.dot_product(u, from) },
        .{ -f[0], -f[1], -f[2], vec.dot_product(f, from) },
        .{ 0, 0, 0, 1 },
    } };
}
