const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const ctx = @import("context.zig");
const prim = @import("primitives.zig");

// P: Main function

var tri = prim.Triangle{
    .v0 = .{ 10, 10 },
    .v1 = .{ 350, 750 },
    .v2 = .{ 750, 350 },
};

pub fn main() !void {
    // const width: c_int = 240;
    // const height: c_int = 135;
    // const scale: c_int = 8;

    const width: c_int = 1920;
    const height: c_int = 1080;
    const scale: c_int = 1;

    var gfx = try ctx.SdlGfx.init(width, height, scale);

    var running = true;
    var t: usize = 0;

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

        var framebuffer = try gfx.begin_frame();

        // const bounding_box = tri.get_bounding_box();

        // NOTE: Show triangle bounding box

        tri.render_triangle(&framebuffer);

        tri.v0[0] += 1;

        gfx.end_frame();
        gfx.present();

        framebuffer.clear(0x00000000);
    }
}
