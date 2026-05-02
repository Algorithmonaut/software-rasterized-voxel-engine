const std = @import("std");
const types = @import("types.zig");
const vec = @import("math/vector.zig");
const helpers = @import("helpers.zig");

const F3 = types.F3;
const Camera = @import("game/Camera.zig").Camera;

// Doing this per pixel is way to expansive.
// Instead we proceed with a camera-pitch-dependant row LUT

inline fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);

    return @intFromFloat(af + (bf - af) * t);
}

pub fn skyColorFromDirY(dir_y: f32) u32 {
    // Horizon: #9EDBFF
    const horizon_r: u8 = 0x9E;
    const horizon_g: u8 = 0xDB;
    const horizon_b: u8 = 0xFF;

    // Top: #4A90FF
    const top_r: u8 = 0x4A;
    const top_g: u8 = 0x90;
    const top_b: u8 = 0xFF;

    const t = helpers.clamp01(dir_y);
    // Make the darker top color appear before looking perfectly straight up.
    // t = clamp01(t / 0.75);

    return helpers.packColor(
        lerpU8(horizon_r, top_r, t),
        lerpU8(horizon_g, top_g, t),
        lerpU8(horizon_b, top_b, t),
    );
}

pub fn buildSkyRowsForCamera(sky_rows: []u32, camera: *Camera) void {
    const h: f32 = @floatFromInt(sky_rows.len);

    // opposite / adjacent * 0.5
    //
    // Side view of the camera:
    //
    //            top of view
    //                │
    //                │ view plane half-height
    //                │
    // camera >───────┘
    //         distance = 1
    //
    // So adjacent = 1 => this gives us the half-height of a virtual view plane
    const fov_scale: f32 = @tan((camera.fov * std.math.pi / 180) * 0.5);

    const world_up = F3{ 0, 1, 0 };

    const forward = vec.normalize(camera.to - camera.from);
    const right = vec.cross_product(forward, world_up);
    const up = vec.cross_product(right, forward);

    for (sky_rows, 0..) |*out, y| {
        const yf: f32 = @floatFromInt(y);

        // ~[-1, +1], 0.5 because we sample at pixel center
        const ndc_y = 1.0 - ((yf + 0.5) / h) * 2.0;

        const sy = ndc_y * fov_scale;

        const ray = vec.normalize(forward + vec.scale(up, sy));

        out.* = skyColorFromDirY(ray[1]);
    }
}
