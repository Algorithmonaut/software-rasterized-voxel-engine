// NOTE: Vectors are column-major
//       Matrices are row-major

const std = @import("std");
const cfg = @import("config.zig");
const ctx = @import("context.zig");
const vec = @import("vector.zig");

const float = f32;
const vec4f = cfg.vec4f;
const vec3f = cfg.vec3f;

pub const Mat4f = struct {
    r: [4]vec4f,

    pub inline fn identity() Mat4f {
        return .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        };
    }

    pub inline fn mul_vec(self: Mat4f, v: vec4f) vec4f {
        return .{
            @reduce(.Add, self.r[0] * v),
            @reduce(.Add, self.r[1] * v),
            @reduce(.Add, self.r[2] * v),
            @reduce(.Add, self.r[3] * v),
        };
    }

    inline fn row_times_cols(row: vec4f, col0: vec4f, col1: vec4f, col2: vec4f, col3: vec4f) vec4f {
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
        const c0: vec4f = .{ b.r[0][0], b.r[1][0], b.r[2][0], b.r[3][0] };
        const c1: vec4f = .{ b.r[0][1], b.r[1][1], b.r[2][1], b.r[3][1] };
        const c2: vec4f = .{ b.r[0][2], b.r[1][2], b.r[2][2], b.r[3][2] };
        const c3: vec4f = .{ b.r[0][3], b.r[1][3], b.r[2][3], b.r[3][3] };

        return .{ .r = .{
            row_times_cols(self.r[0], c0, c1, c2, c3),
            row_times_cols(self.r[1], c0, c1, c2, c3),
            row_times_cols(self.r[2], c0, c1, c2, c3),
            row_times_cols(self.r[3], c0, c1, c2, c3),
        } };
    }

    pub inline fn rotate_y(rad: float) Mat4f {
        const c = @cos(rad);
        const s = @sin(rad);

        return .{ .r = .{
            .{ c, 0, s, 0 },
            .{ 0, 1, 0, 0 },
            .{ -s, 0, c, 0 },
            .{ 0, 0, 0, 1 },
        } };
    }

    pub inline fn rotate_z(rad: float) Mat4f {
        const c = @cos(rad);
        const s = @sin(rad);

        return .{ .r = .{
            .{ c, -s, 0, 0 },
            .{ s, c, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        } };
    }
};

pub fn create_projection_matrix() Mat4f {
    const far = cfg.view_distance;
    const near = 1;

    const w: float = @floatFromInt(cfg.width);
    const h: float = @floatFromInt(cfg.height);
    const aspect: float = w / h;

    const y_scale: float = 1.0 / @tan(cfg.fov * std.math.pi / 360.0);
    const x_scale: float = y_scale / aspect;

    return .{ .r = .{
        .{ x_scale, 0, 0, 0 },
        .{ 0, y_scale, 0, 0 },
        .{ 0, 0, (-far) / (far - near), -(far * near) / (far - near) },
        .{ 0, 0, -1, 0 },
    } };
}

pub inline fn world_to_camera() Mat4f {
    const from = ctx.from;
    const to = ctx.to;
    const world_up = vec3f{ 0, 1, 0 };

    const f = vec.normalize(to - from); // forward (world)
    var s = vec.normalize(vec.cross_product(f, world_up)); // right

    const u = vec.cross_product(s, f); // up (already orthogonal if r,f are)

    // Right-handed view: camera forward is -Z, so use -f in the basis
    return .{ .r = .{
        .{ s[0], s[1], s[2], -vec.dot_product(s, from) },
        .{ u[0], u[1], u[2], -vec.dot_product(u, from) },
        .{ -f[0], -f[1], -f[2], vec.dot_product(f, from) },
        .{ 0, 0, 0, 1 },
    } };
}
