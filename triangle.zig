const std = @import("std");
const types = @import("math/types.zig");
const Float = types.Float;

const Edge = @import("renderer/TrianglesRasterizer.zig").Edge;
const UV = @Vector(2, Float);

const Vec2fx = types.Vec2fx;
const SUBPIXEL_BITS = types.SUBPIXEL_BITS;
const SUBPIXEL_MASK = (1 << SUBPIXEL_BITS) - 1;

inline fn floorFixed(x: i32) i32 {
    return x >> SUBPIXEL_BITS;
}

inline fn ceilFixed(x: i32) i32 {
    return (x + SUBPIXEL_MASK) >> SUBPIXEL_BITS;
}

pub const RasterTriangle = struct {
    v0: Vec2fx,
    v1: Vec2fx,
    v2: Vec2fx,

    e0: Edge = undefined,
    e1: Edge = undefined,
    e2: Edge = undefined,

    area: i64 = undefined,
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

    pub inline fn boundingBox(
        self: RasterTriangle,
        fb_width: usize,
        fb_height: usize,
    ) struct {
        min_x: usize,
        max_x: usize,
        min_y: usize,
        max_y: usize,
    } {
        const min_x_i = floorFixed(@min(self.v0[0], self.v1[0], self.v2[0]));
        const min_y_i = floorFixed(@min(self.v0[1], self.v1[1], self.v2[1]));
        const max_x_i = ceilFixed(@max(self.v0[0], self.v1[0], self.v2[0]));
        const max_y_i = ceilFixed(@max(self.v0[1], self.v1[1], self.v2[1]));

        const fb_w_i: i32 = @intCast(fb_width);
        const fb_h_i: i32 = @intCast(fb_height);

        return .{
            .min_x = @intCast(std.math.clamp(min_x_i, 0, fb_w_i)),
            .max_x = @intCast(std.math.clamp(max_x_i, 0, fb_w_i)),
            .min_y = @intCast(std.math.clamp(min_y_i, 0, fb_h_i)),
            .max_y = @intCast(std.math.clamp(max_y_i, 0, fb_h_i)),
        };
    }
};
