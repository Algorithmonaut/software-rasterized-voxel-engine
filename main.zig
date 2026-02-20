const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const cfg = @import("config.zig");
const sdl_gfx = @import("sdl-graphics.zig");
const triangle = @import("triangle.zig");
const cube = @import("cube.zig");

// P: Main function

pub fn main() !void {
    var gfx = try sdl_gfx.SdlGfx.init(cfg.width, cfg.height, cfg.scale);

    var running = true;
    var t: usize = 0;

    const freq: u64 = c.SDL_GetPerformanceFrequency();
    var last: u64 = c.SDL_GetPerformanceCounter();
    var frames: u64 = 0;

    var framebuffer = try gfx.begin_frame();

    var cube1 = cube.Cube{
        .vertices = cube.vertices,
        .idx = cube.idx,
    };

    while (running) : (t += 1) {
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    if (ev.key.keysym.sym == c.SDLK_ESCAPE) running = false;
                },
                else => {},
            }
        }

        // tri.render_triangle(&framebuffer);

        cube1.render_cube(&framebuffer);

        gfx.end_frame();
        gfx.present();

        framebuffer.clear(0x00000000);
        framebuffer.clear_z();

        // Show fps
        frames += 1 % 0xFFFF;
        const now: u64 = c.SDL_GetPerformanceCounter();
        const dt_counts: u64 = now - last;

        if (dt_counts >= freq) { // ~1 second
            const seconds: f64 =
                @as(f64, @floatFromInt(dt_counts)) / @as(f64, @floatFromInt(freq));
            const fps: f64 =
                @as(f64, @floatFromInt(frames)) / seconds;

            std.debug.print("FPS: {d:.1}\n", .{fps});

            frames = 0;
            last = now;
        }
    }

    // var cu: cube.Cube = .{};
    // cube1.render_cube(&framebuffer);
}
