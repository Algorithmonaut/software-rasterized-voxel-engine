const Tile = @import("tile.zig");
const Atlas = @import("Atlas.zig").Atlas;
const std = @import("std");
const cfg = @import("config.zig");
const Float = cfg.Float;
const Int = cfg.Int;
const Vec3f = cfg.Vec3f;
const Vec4f = cfg.Vec4f;
const Vec3i = cfg.Vec3i;
const Vec4i = cfg.Vec4i;
const mat = @import("math/matrix.zig");
const ctx = @import("context.zig");

pub const RasterTriangle = struct {
    v0: @Vector(2, Int),
    v0_uv: @Vector(2, usize),
    v0_rec_z: f32,
    v1: @Vector(2, Int),
    v1_uv: @Vector(2, usize),
    v1_rec_z: f32,
    v2: @Vector(2, Int),
    v2_uv: @Vector(2, usize),
    v2_rec_z: f32,

    /// Max is exclusive
    pub inline fn boundingBox(self: RasterTriangle) struct {
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
        const min_x_c = std.math.clamp(min_x, 0, cfg.width);
        const min_y_c = std.math.clamp(min_y, 0, cfg.height);

        // Convert inclusive max -> exclusive max, then clamp to [0, width/height]
        const max_x_excl = std.math.clamp(max_x_incl + 1, 0, cfg.width);
        const max_y_excl = std.math.clamp(max_y_incl + 1, 0, cfg.height);

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
