const std = @import("std");
const tri = @import("triangle.zig");
const matrix = @import("matrix.zig");
const fb = @import("framebuffer.zig");
const cfg = @import("config.zig");
const float = cfg.f;

const Vec4 = @Vector(4, float);

pub const vertices: [8]Vec4 = .{
    .{ -1, -1, -1, 1 },
    .{ 1, -1, -1, 1 },
    .{ 1, 1, -1, 1 },
    .{ -1, 1, -1, 1 },
    .{ -1, -1, 1, 1 },
    .{ 1, -1, 1, 1 },
    .{ 1, 1, 1, 1 },
    .{ -1, 1, 1, 1 },
};

pub const idx: [36]u16 = .{
    0, 1, 2, 0, 2, 3, // back
    4, 6, 5, 4, 7, 6, // front
    0, 3, 7, 0, 7, 4, //left
    1, 5, 6, 1, 6, 2, // right
    0, 4, 5, 0, 5, 1, // bottom
    3, 2, 6, 3, 6, 7, //top
};

pub const Cube = struct {
    vertices: [8]Vec4,
    idx: [36]u16,

    // Triangles are oriented counter-clockwise

    // inline fn perspective_divide(v: Vec4) Vec4 {
    //     return .{ v[0] / v[2], v[1] / v[2], v[2], v[3] };
    // }

    pub inline fn render_cube(self: *Cube, buf: *fb.Framebuffer) void {
        const angle: float = 3.14 / 2000.0;
        const rotation_mat_y = matrix.Mat4f.rotate_y(angle);
        const rotation_mat_z = matrix.Mat4f.rotate_z(angle);

        const rotation_mat = rotation_mat_y.mul(rotation_mat_z);
        for (&self.vertices) |*vertex| {
            vertex.* = rotation_mat.mul_vec(vertex.*);
        }

        var translated_vertices = self.vertices;

        for (&translated_vertices) |*v| {
            v.*[2] += 10;
            v.*[0] *= 1000;
            v.*[1] *= 1000;
        }

        var i: usize = 0;
        while (i < idx.len) : (i += 3) {
            const v0 = translated_vertices[idx[i]];
            const v1 = translated_vertices[idx[i + 1]];
            const v2 = translated_vertices[idx[i + 2]];

            var triangle = tri.Triangle{
                .v0 = v0,
                .v1 = v1,
                .v2 = v2,

                .v0_col = 0xFFFF0000,
                .v1_col = 0xFF00FF00,
                .v2_col = 0xFF0000FF,
            };

            triangle.render_triangle(buf);
        }
    }

    pub inline fn render_cube_2(self: *Cube, buf: *fb.Framebuffer) void {
        const angle: float = 3.14 / 2000.0;
        const rotation_mat = matrix.Mat4f.rotate_y(angle);

        for (&self.vertices) |*vertex| {
            vertex.* = rotation_mat.mul_vec(vertex.*);
        }

        var translated_vertices = self.vertices;

        for (&translated_vertices) |*v| {
            v.*[2] += 10;
            v.*[0] *= 1000;
            v.*[1] *= 1000;
        }

        var i: usize = 0;
        while (i < idx.len) : (i += 3) {
            const v0 = translated_vertices[idx[i]];
            const v1 = translated_vertices[idx[i + 1]];
            const v2 = translated_vertices[idx[i + 2]];

            var triangle = tri.Triangle{
                .v0 = v0,
                .v1 = v1,
                .v2 = v2,

                .v0_col = 0xFFFF0000,
                .v1_col = 0xFF00FF00,
                .v2_col = 0xFF0000FF,
            };

            triangle.render_triangle(buf);
        }
    }
};
