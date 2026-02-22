const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const cfg = @import("config.zig");
const sdl_gfx = @import("sdl-graphics.zig");
const cube = @import("cube.zig");
const sdl_platform = @import("sdl-platform.zig");
const ctx = @import("context.zig");
const mat = @import("matrix.zig");

pub fn main() !void {
    var gfx = try sdl_gfx.SdlGfx.init();
    var platform = sdl_platform.SdlPlatform.init();

    var cube1 = cube.Cube.init();

    ctx.projection_matrix = mat.create_projection_matrix();

    var t: usize = 0;

    while (platform.running) : (t += 1) {
        const dt = platform.begin_frame();
        var framebuffer = try gfx.begin_frame();
        framebuffer.clear_all();

        cube1.render(&framebuffer);

        gfx.end_frame();
        gfx.present();

        if (cfg.show_fps) platform.fps_counter_update();

        platform.update_camera_look(dt);
        platform.process_inputs(dt);
    }
}
