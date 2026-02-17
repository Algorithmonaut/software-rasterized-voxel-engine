const std = @import("std");
const tri = @import("primitives.zig");
const ctx = @import("context.zig");

const Vec4 = @Vector(4, f32);

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

    inline fn perspective_divide(v: Vec4) Vec4 {
        return .{ v[0] / v[2], v[1] / v[2], v[2], v[3] };
    }

    pub inline fn render_cube(self: *Cube, fb: *ctx.Framebuffer) void {
        var proj_vertices: [8]Vec4 = undefined;
        for (self.vertices, 0..) |vertex, i| {
            proj_vertices[i][0] = vertex[0] * 1000 / -(vertex[2]);
            proj_vertices[i][1] = vertex[1] * 1000 / -(vertex[2]);
            proj_vertices[i][2] = vertex[2];
            proj_vertices[i][3] = vertex[3];
        }

        var i: usize = 0;
        while (i < idx.len) : (i += 3) {
            const v0 = proj_vertices[idx[i]];
            const v1 = proj_vertices[idx[i + 1]];
            const v2 = proj_vertices[idx[i + 2]];

            const v0_2di = @Vector(2, i32){ @intFromFloat(v0[0]), @intFromFloat(v0[1]) };
            const v1_2di = @Vector(2, i32){ @intFromFloat(v1[0]), @intFromFloat(v1[1]) };
            const v2_2di = @Vector(2, i32){ @intFromFloat(v2[0]), @intFromFloat(v2[1]) };

            var triangle = tri.Triangle{
                .v0 = v0_2di,
                .v1 = v1_2di,
                .v2 = v2_2di,

                .v0_col = 0xFFFF0000,
                .v1_col = 0xFF00FF00,
                .v2_col = 0xFF0000FF,
            };

            triangle.render_triangle(fb);
        }
    }

    pub inline fn move_back(self: *Cube, factor: f32) void {
        for (&self.vertices) |*v| {
            v.*[2] -= factor;
        }

        for (&self.vertices) |*v| {
            v.*[1] += 2;
        }

        for (&self.vertices) |*v| {
            v.*[0] += 4;
        }
    }
};
