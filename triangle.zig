const Tile = @import("tile.zig");
const Atlas = @import("Atlas.zig").Atlas;
const std = @import("std");
const t = @import("math/types.zig");
const Float = t.Float;
const Int = t.Int;
const Vec3f = t.Vec3f;
const Vec4f = t.Vec4f;
const Vec3i = t.Vec3i;
const Vec4i = t.Vec4i;
const mat = @import("math/matrix.zig");
const ctx = @import("context.zig");

const TriangleRasterizer = @import("renderer/TrianglesRasterizer.zig");
const Edge = TriangleRasterizer.Edge;

const UV = @Vector(2, Float);

pub const RasterTriangle = struct {
    v0: @Vector(2, Int),
    v1: @Vector(2, Int),
    v2: @Vector(2, Int),

    e0: Edge = undefined,
    e1: Edge = undefined,
    e2: Edge = undefined,

    area: i32 = undefined,
    inv_area: Float = undefined,

    q0: f32 = undefined,
    q1: f32 = undefined,
    q2: f32 = undefined,

    uv0: UV = undefined,
    uv1: UV = undefined,
    uv2: UV = undefined,

    // Used to warp the texture of greedy merged quads
    tex_u: usize,
    tex_v: usize,
    tex_tile_size: usize,

    /// Max is exclusive
    pub inline fn boundingBox(self: RasterTriangle, fb_width: usize, fb_height: usize) struct {
        min_x: usize,
        max_x: usize,
        min_y: usize,
        max_y: usize,
    } {
        const a = self.v0;
        const b = self.v1;
        const c = self.v2;

        const min_x = @min(a[0], b[0], c[0]);
        const max_x_incl = @max(a[0], b[0], c[0]);

        const min_y = @min(a[1], b[1], c[1]);
        const max_y_incl = @max(a[1], b[1], c[1]);

        // Clamp min to [0, width/height] (min is inclusive)
        const min_x_c = std.math.clamp(min_x, 0, fb_width);
        const min_y_c = std.math.clamp(min_y, 0, fb_height);

        // Convert inclusive max -> exclusive max, then clamp to [0, width/height]
        const max_x_excl = std.math.clamp(max_x_incl + 1, 0, fb_width);
        const max_y_excl = std.math.clamp(max_y_incl + 1, 0, fb_height);

        return .{
            .min_x = min_x_c,
            .max_x = max_x_excl,
            .min_y = min_y_c,
            .max_y = max_y_excl,
        };
    }
};

pub const Triangle = struct {
    v0: @Vector(4, f32),
    v0_uv: @Vector(2, usize),
    v1: @Vector(4, f32),
    v1_uv: @Vector(2, usize),
    v2: @Vector(4, f32),
    v2_uv: @Vector(2, usize),
};
