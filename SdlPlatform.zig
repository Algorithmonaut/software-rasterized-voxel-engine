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
const SdlGraphics = @import("SdlGraphics.zig").SdlGraphics;

const Vec3f = cfg.Vec3f;

pub const SdlPlatform = struct {
    freq: u64, // tick counter
    last_frame: u64, // ticks per second
    last_fps: u64,
    now: u64,
    frames: u64, // frame counter
    running: bool,
    drop_next_mouse_delta: bool,

    mouse_capture: bool,
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
            .mouse_capture = true,
            .drop_next_mouse_delta = false,
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

    pub fn process_inputs(self: *SdlPlatform, dt: f32, camera: *Camera, sdl_gfx: *SdlGraphics) void {
        while (c.SDL_PollEvent(&self.ev) != 0) {
            switch (self.ev.type) {
                c.SDL_QUIT => self.running = false,
                c.SDL_KEYDOWN => {
                    const key = self.ev.key.keysym.sym;

                    if (self.ev.key.repeat == 0 and key == c.SDLK_TAB) {
                        self.mouse_capture = !self.mouse_capture;
                        self.drop_next_mouse_delta = !self.drop_next_mouse_delta;

                        _ = c.SDL_SetRelativeMouseMode(if (self.mouse_capture) c.SDL_TRUE else c.SDL_FALSE);

                        if (self.mouse_capture) self.drop_next_mouse_delta = true;

                        _ = sdl_gfx;
                        // if (!self.mouse_capture) {
                        //     const w: c_int = sdl_gfx.width * sdl_gfx.scale;
                        //     const h: c_int = sdl_gfx.height * sdl_gfx.scale;
                        //     c.SDL_WarpMouseInWindow(@as(?*c.SDL_Window, sdl_gfx.window), w / 2, h / 2);
                        // }
                    }
                },

                else => {},
            }
        }

        {
            var dx: i32 = 0;
            var dy: i32 = 0;

            if (self.mouse_capture) {
                _ = c.SDL_GetRelativeMouseState(&dx, &dy);

                if (self.drop_next_mouse_delta) {
                    dx = 0;
                    dy = 0;
                    self.drop_next_mouse_delta = false;
                }
            }

            const keys = c.SDL_GetKeyboardState(null);
            const mov_keys = Camera.MoveKeys{
                .forward = keys[c.SDL_SCANCODE_W] != 0,
                .back = keys[c.SDL_SCANCODE_S] != 0,
                .right = keys[c.SDL_SCANCODE_D] != 0,
                .left = keys[c.SDL_SCANCODE_A] != 0,
                .up = keys[c.SDL_SCANCODE_SPACE] != 0,
                .down = keys[c.SDL_SCANCODE_E] != 0,
            };

            camera.update(dx, dy, mov_keys, dt);
        }
    }
};
