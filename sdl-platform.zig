const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const cfg = @import("config.zig");

pub const SdlPlatform = struct {
    freq: u64, // tick counter
    last: u64, // ticks per second
    frames: u64, // frame counter

    running: bool,

    ev: c.SDL_Event,

    pub fn init() SdlPlatform {
        return .{
            .freq = c.SDL_GetPerformanceFrequency(),
            .last = c.SDL_GetPerformanceCounter(),
            .frames = 0,
            .running = true,
            .ev = undefined,
        };
    }

    pub fn fps_counter_update(self: *SdlPlatform) void {
        self.frames +%= 1; // wraps on overflow
        const now: u64 = c.SDL_GetPerformanceCounter();
        const dt_counts: u64 = now - self.last;

        if (dt_counts >= self.freq) { // ~1 sec
            const seconds: f64 = @as(f64, @floatFromInt(dt_counts)) /
                @as(f64, @floatFromInt(self.freq));

            const fps: f64 = @as(f64, @floatFromInt(self.frames)) / seconds;

            std.debug.print("FPS: {d:.1}\n", .{fps});

            self.frames = 0;
            self.last = now;
        }
    }

    pub fn process_inputs(self: *SdlPlatform) void {
        while (c.SDL_PollEvent(&self.ev) != 0) {
            switch (self.ev.type) {
                c.SDL_QUIT => self.running = false,
                else => {},
            }
        }
    }
};
