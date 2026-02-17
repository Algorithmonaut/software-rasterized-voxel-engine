// NOTE: Vectors are column-major
//       Matrices are row-major

const std = @import("std");

pub const T = f32;
pub const V4 = @Vector(4, T);

pub const Mat4f = struct {
    r: [4]V4,

    pub inline fn identity() Mat4f {
        return .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        };
    }

    pub inline fn mul_vec(self: Mat4f, v: V4) V4 {
        return .{
            @reduce(.Add, self.r[0] * v),
            @reduce(.Add, self.r[1] * v),
            @reduce(.Add, self.r[2] * v),
            @reduce(.Add, self.r[3] * v),
        };
    }

    inline fn row_times_cols(row: V4, col0: V4, col1: V4, col2: V4, col3: V4) V4 {
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
        const c0: V4 = .{ b[0][0], b[1][0], b[2][0] };
        const c1: V4 = .{ b[0][1], b[1][1], b[2][1] };
        const c2: V4 = .{ b[0][2], b[1][2], b[2][2] };
        const c3: V4 = .{ b[0][3], b[1][3], b[2][3] };

        return .{
            row_times_cols(self.r[0], c0, c1, c2, c3),
            row_times_cols(self.r[1], c0, c1, c2, c3),
            row_times_cols(self.r[2], c0, c1, c2, c3),
            row_times_cols(self.r[3], c0, c1, c2, c3),
        };
    }

    pub inline fn rotate_y(rad: T) Mat4f {
        const c = @cos(rad);
        const s = @sin(rad);

        return .{ .r = .{
            .{ c, 0, s, 0 },
            .{ 0, 1, 0, 0 },
            .{ -s, 0, c, 0 },
            .{ 0, 0, 0, 1 },
        } };
    }
};
