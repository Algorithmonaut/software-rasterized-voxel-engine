const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const ctx = @import("context.zig");
const prim = @import("primitives.zig");
const cube = @import("cube.zig");

// P: Main function

var tri = prim.Triangle{
    .v0 = .{ 10, 10 },
    .v0_col = 0xFFFF0000,
    .v2 = .{ 950, 450 },
    .v1_col = 0xFF00FF00,
    .v1 = .{ 450, 350 },
    .v2_col = 0xFF0000FF,
};

// var tri2 = prim.Triangle{
//     .v0 = .{ 40, 80 },
//     .v0_col = 0xFFFF0000,
//     .v2 = .{ 450, 950 },
//     .v1_col = 0xFF00FF00,
//     .v1 = .{ 350, 550 },
//     .v2_col = 0xFF0000FF,
// };

pub fn main() !void {
    // const width: c_int = 240;
    // const height: c_int = 135;
    // const scale: c_int = 8;

    const width: c_int = 960;
    const height: c_int = 540;
    const scale: c_int = 2;

    var gfx = try ctx.SdlGfx.init(width, height, scale);

    var running = true;
    var t: usize = 0;

    var vertical_dir: i32 = 1;
    var horizontal_dir: i32 = 1;

    const freq: u64 = c.SDL_GetPerformanceFrequency();
    var last: u64 = c.SDL_GetPerformanceCounter();
    var frames: u64 = 0;

    var framebuffer = try gfx.begin_frame();

    var cube1 = cube.Cube{
        .vertices = cube.vertices,
        .idx = cube.idx,
    };
    cube1.move_back(10);

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

        tri.v0[0] += vertical_dir;
        tri.v1[1] += horizontal_dir;

        if (tri.v0[0] == framebuffer.width) {
            vertical_dir = -vertical_dir;
        } else if (tri.v0[0] == 0) {
            vertical_dir = -vertical_dir;
        }
        if (tri.v1[1] == framebuffer.height) {
            horizontal_dir = -horizontal_dir;
        } else if (tri.v1[1] == 0) {
            horizontal_dir = -horizontal_dir;
        }

        gfx.end_frame();
        gfx.present();

        framebuffer.clear(0x00000000);

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
