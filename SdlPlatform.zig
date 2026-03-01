// NOTE: Refactored: YES

const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const cfg = @import("config.zig");
const ctx = @import("context.zig");
const vec = @import("vector.zig");
const Camera = @import("Camera.zig").Camera;

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

    pub fn deinit(self: *SdlPlatform) void {
        _ = self;
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

    pub fn process_inputs(self: *SdlPlatform, dt: f32, camera: *Camera) void {
        while (c.SDL_PollEvent(&self.ev) != 0) {
            switch (self.ev.type) {
                c.SDL_QUIT => self.running = false,
                else => {},
            }
        }

        {
            var dx: i32 = 0;
            var dy: i32 = 0;
            _ = c.SDL_GetRelativeMouseState(&dx, &dy);

            const keys = c.SDL_GetKeyboardState(null);
            const mov_keys = Camera.MoveKeys{
                .forward = keys[c.SDL_SCANCODE_W] != 0,
                .back = keys[c.SDL_SCANCODE_S] != 0,
                .right = keys[c.SDL_SCANCODE_D] != 0,
                .left = keys[c.SDL_SCANCODE_A] != 0,
            };

            camera.update(dx, dy, mov_keys, dt);
        }
    }
};
