const std = @import("std");
const main = @import("main.zig");
const tri = @import("triangle.zig");
const mat = @import("math/matrix.zig");
const cfg = @import("config.zig");
const BlockTypes = @import("Atlas.zig").BlockTypes;
const Float = cfg.Float;
const Vec4f = cfg.Vec4f;
const Vec3f = cfg.Vec3f;
const Renderer = @import("Renderer.zig").Renderer;
const Camera = @import("Camera.zig").Camera;
const Atlas = @import("Atlas.zig").Atlas;
const Framebuffer = @import("Framebuffer.zig").Framebuffer;

const vertices: [8]Vec4f = .{
    .{ -1, -1, -1, 1 },
    .{ 1, -1, -1, 1 },
    .{ 1, 1, -1, 1 },
    .{ -1, 1, -1, 1 },
    .{ -1, -1, 1, 1 },
    .{ 1, -1, 1, 1 },
    .{ 1, 1, 1, 1 },
    .{ -1, 1, 1, 1 },
};

const idx: [36]u16 = .{
    0, 1, 2, 0, 2, 3, // back
    4, 6, 5, 4, 7, 6, // front
    0, 3, 7, 0, 7, 4, //left
    1, 5, 6, 1, 6, 2, // right
    0, 4, 5, 0, 5, 1, // bottom
    3, 2, 6, 3, 6, 7, //top
};

pub const Cube = struct {
    vertices: [8]Vec4f,
    idx: [36]u16,
    kind: BlockTypes,

    pub fn init(kind: BlockTypes) Cube {
        return .{
            .vertices = vertices,
            .idx = idx,
            .kind = kind,
        };
    }

    pub inline fn genRasterTriangles(
        self: *Cube,
        renderer: *Renderer,
        camera: *Camera,
        atlas: *Atlas,
        out: []tri.RasterTriangle,
        pos: Vec4f,
    ) u8 {
        var n: u8 = 0;

        const view = camera.view_mat;
        var verts_cpy = self.vertices;

        for (&verts_cpy) |*vertex| {
            vertex.* += pos;
            vertex.* = view.mul_vec(vertex.*);
        }

        const cube_start_x = 0;
        const cube_start_y = @intFromEnum(self.kind) * atlas.tex_h;

        var i: usize = 0;
        while (i < idx.len) : (i += 6) {
            const face: usize = i / 6;

            const tex_start_x = cube_start_x + face * atlas.tex_w;
            const tex_start_y = cube_start_y;

            const v0 = verts_cpy[idx[i]];
            const v1 = verts_cpy[idx[i + 1]];
            const v2 = verts_cpy[idx[i + 2]];
            const v3 = verts_cpy[idx[i + 3]];
            const v4 = verts_cpy[idx[i + 4]];
            const v5 = verts_cpy[idx[i + 5]];

            const u_0 = tex_start_x;
            const u_1 = tex_start_x + (atlas.tex_w - 1); // FIX: Why -1 ????
            const v_0 = tex_start_y;
            const v_1 = tex_start_y + (atlas.tex_h - 1);

            // Canonical corners
            const uv_tl = @Vector(2, usize){ u_0, v_0 }; // top left
            const uv_tr = @Vector(2, usize){ u_1, v_0 };
            const uv_bl = @Vector(2, usize){ u_0, v_1 };
            const uv_br = @Vector(2, usize){ u_1, v_1 };

            var uv0: @Vector(2, usize) = undefined;
            var uv1: @Vector(2, usize) = undefined;
            var uv2: @Vector(2, usize) = undefined;
            var uv3: @Vector(2, usize) = undefined;
            var uv4: @Vector(2, usize) = undefined;
            var uv5: @Vector(2, usize) = undefined;

            switch (face) {
                // back (0,1,2) and (0,2,3)
                0 => {
                    uv0 = uv_bl;
                    uv1 = uv_br;
                    uv2 = uv_tr;
                    uv3 = uv_bl;
                    uv4 = uv_tr;
                    uv5 = uv_tl;
                },
                // front (4,6,5) and (4,7,6)
                1 => {
                    uv0 = uv_bl;
                    uv1 = uv_tr;
                    uv2 = uv_br;
                    uv3 = uv_bl;
                    uv4 = uv_tl;
                    uv5 = uv_tr;
                },
                // left (0,3,7) and (0,7,4)
                2 => {
                    uv0 = uv_bl;
                    uv1 = uv_tl;
                    uv2 = uv_tr;
                    uv3 = uv_bl;
                    uv4 = uv_tr;
                    uv5 = uv_br;
                },
                // right (1,5,6) and (1,6,2)
                3 => {
                    uv0 = uv_bl;
                    uv1 = uv_br;
                    uv2 = uv_tr;
                    uv3 = uv_bl;
                    uv4 = uv_tr;
                    uv5 = uv_tl;
                },
                // bottom (0,4,5) and (0,5,1)
                4 => {
                    uv0 = uv_tr;
                    uv1 = uv_tl;
                    uv2 = uv_bl;
                    uv3 = uv_tr;
                    uv4 = uv_bl;
                    uv5 = uv_br;
                },
                // top (3,2,6) and (3,6,7)
                5 => {
                    uv0 = uv_tl;
                    uv1 = uv_tr;
                    uv2 = uv_br;
                    uv3 = uv_tl;
                    uv4 = uv_br;
                    uv5 = uv_bl;
                },
                else => unreachable,
            }

            var triangle = tri.Triangle{
                .v0 = v0,
                .v1 = v1,
                .v2 = v2,
                .v0_uv = uv0,
                .v1_uv = uv1,
                .v2_uv = uv2,
            };

            var triangle2 = tri.Triangle{
                .v0 = v3,
                .v1 = v4,
                .v2 = v5,
                .v0_uv = uv3,
                .v1_uv = uv4,
                .v2_uv = uv5,
            };

            if (renderer.gen_raster_triangle(&triangle, camera)) |rt| {
                out[n] = rt;
                n += 1;
            }

            if (renderer.gen_raster_triangle(&triangle2, camera)) |rt| {
                out[n] = rt;
                n += 1;
            }
        }

        return n;
    }
};
