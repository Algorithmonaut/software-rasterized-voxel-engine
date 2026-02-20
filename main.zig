const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const cfg = @import("config.zig");
const sdl_gfx = @import("sdl-graphics.zig");
const cube = @import("cube.zig");
const sdl_platform = @import("sdl-platform.zig");

pub fn main() !void {
    var gfx = try sdl_gfx.SdlGfx.init();
    var platform = sdl_platform.SdlPlatform.init();

    var cube1 = cube.Cube.init();

    while (platform.running) {
        var framebuffer = try gfx.begin_frame();

        cube1.render(&framebuffer);

        gfx.end_frame();
        gfx.present();

        framebuffer.clear_all();

        if (cfg.show_fps) platform.fps_counter_update();
        platform.process_inputs();
    }
}
