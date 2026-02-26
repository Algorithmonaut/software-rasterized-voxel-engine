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
const tex = @import("textures.zig");
const fb = @import("framebuffer.zig");
const tile = @import("tile.zig");

fn render_job(wg: *std.Thread.WaitGroup, prim: *cube.Cube, buf: *fb.Framebuffer) void {
    defer wg.finish();
    prim.render(buf);
}

pub fn main() !void {
    @setFloatMode(.optimized);

    // Init thread pool
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // const allocator = gpa.allocator();
    // var pool: std.Thread.Pool = undefined;
    // try pool.init(.{
    //     .allocator = allocator,
    // });
    // var wg: std.Thread.WaitGroup = undefined;
    // wg.reset();

    var gfx = try sdl_gfx.SdlGfx.init();
    var platform = sdl_platform.SdlPlatform.init();

    var tiles = tile.TilePool.init();

    var cube1 = cube.Cube.init(.{ 0, 0, 0, 0 }, tex.BlockTypes.grass);
    var cube2 = cube.Cube.init(.{ 4, 0, 0, 0 }, tex.BlockTypes.stone);
    var cube3 = cube.Cube.init(.{ 8, 0, 0, 0 }, tex.BlockTypes.dirt);

    ctx.projection_matrix = mat.create_projection_matrix();

    ctx.atlas = try tex.Atlas.init();

    var t: usize = 0;

    while (platform.running) : (t += 1) {
        const dt = platform.begin_frame();

        var framebuffer = try gfx.begin_frame();
        framebuffer.clear_all();

        const view: mat.Mat4f = mat.world_to_camera();
        cube2.render(&framebuffer, view);
        cube1.render(&framebuffer, view);
        cube3.render(&framebuffer, view);

        if (cfg.show_tex_atlas) ctx.atlas.debug_show_atlas(&framebuffer);

        tiles.debug_show_tiles_border(framebuffer);

        gfx.end_frame();
        gfx.present();

        if (cfg.show_fps) platform.fps_counter_update();

        sdl_platform.update_camera_look();
        platform.process_inputs(dt);
    }
}
