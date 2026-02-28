const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const cfg = @import("config.zig");
const ctx = @import("context.zig");
const vec = @import("vector.zig");

const Vec3f = cfg.Vec3f;

pub const SdlPlatform = struct {
    freq: u64, // tick counter
    last_frame: u64, // ticks per second
    last_fps: u64,
    now: u64,
    frames: u64, // frame counter
    running: bool,

    ev: c.SDL_Event,

    pub fn init() SdlPlatform {
        const freq = c.SDL_GetPerformanceFrequency();
        const now = c.SDL_GetPerformanceCounter();
        return .{
            .freq = freq,
            .last_frame = now,
            .last_fps = now,
            .now = now,
            .frames = 0,
            .running = true,
            .ev = undefined,
        };
    }

    /// Returns dt in seconds
    pub fn begin_frame(self: *SdlPlatform) f32 {
        const now: u64 = c.SDL_GetPerformanceCounter();
        const delta_counts: u64 = now - self.last_frame;
        self.last_frame = now;
        return @as(f32, @floatFromInt(delta_counts)) / @as(f32, @floatFromInt(self.freq));
    }

    pub fn fps_counter_update(self: *SdlPlatform) void {
        self.frames += 1;

        const now: u64 = c.SDL_GetPerformanceCounter();
        const elapsed_counts: u64 = now - self.last_fps;

        if (elapsed_counts >= self.freq) { // ~1 second
            const elapsed_s: f64 =
                @as(f64, @floatFromInt(elapsed_counts)) / @as(f64, @floatFromInt(self.freq));

            const fps: f64 = @as(f64, @floatFromInt(self.frames)) / elapsed_s;
            std.debug.print("FPS: {d:.1}\n", .{fps});

            self.frames = 0;
            self.last_fps = now;
        }
    }

    pub fn process_inputs(self: *SdlPlatform, dt: f32) void {
        while (c.SDL_PollEvent(&self.ev) != 0) {
            switch (self.ev.type) {
                c.SDL_QUIT => self.running = false,
                else => {},
            }
        }

        const keys = c.SDL_GetKeyboardState(null);

        const speed: f32 = 10.0;
        const step: f32 = speed * dt;

        // forward from yaw/pitch (used for look)
        var forward = Vec3f{
            @cos(ctx.pitch) * @sin(ctx.yaw),
            @sin(ctx.pitch),
            @cos(ctx.pitch) * @cos(ctx.yaw),
        };
        forward = vec.normalize(forward);

        const world_up = Vec3f{ 0, 1, 0 };

        // movement basis constrained to horizontal plane
        var fwd_move = forward;
        fwd_move[1] = 0; // y = 0
        if (vec.length_squared(fwd_move) > 0) {
            fwd_move = vec.normalize(fwd_move);
        } else {
            // looking straight up/down: fall back to yaw-only forward
            fwd_move = vec.normalize(Vec3f{ @sin(ctx.yaw), 0, @cos(ctx.yaw) });
        }

        const right = vec.normalize(vec.cross_product(fwd_move, world_up));

        // build wish dir from horizontal basis
        var wish = Vec3f{ 0, 0, 0 };
        if (keys[c.SDL_SCANCODE_W] != 0) wish += fwd_move;
        if (keys[c.SDL_SCANCODE_S] != 0) wish -= fwd_move;
        if (keys[c.SDL_SCANCODE_D] != 0) wish += right;
        if (keys[c.SDL_SCANCODE_A] != 0) wish -= right;

        if (vec.length_squared(wish) > 0) {
            wish = vec.normalize(wish);
            ctx.from += wish * @as(Vec3f, @splat(step));
            ctx.from[1] = 0; // optional: hard clamp to plane y=0
        }
    }
};

pub fn update_camera_look() void {
    var dx: c_int = 0;
    var dy: c_int = 0;
    _ = c.SDL_GetRelativeMouseState(&dx, &dy);

    const sens = cfg.mouse_sensivity;

    ctx.yaw -= @as(f32, @floatFromInt(dx)) * sens;
    ctx.pitch -= @as(f32, @floatFromInt(dy)) * sens;

    // Clamp pitch to avoid flipping at +-90°
    const max_pitch: f32 = 89.0 / 180.0 * std.math.pi;
    ctx.pitch = std.math.clamp(ctx.pitch, -max_pitch, max_pitch);

    var forward = Vec3f{
        @cos(ctx.pitch) * @sin(ctx.yaw),
        @sin(ctx.pitch),
        @cos(ctx.pitch) * @cos(ctx.yaw),
    };
    forward = vec.normalize(forward);

    // set target point
    ctx.to = ctx.from + forward;
}
