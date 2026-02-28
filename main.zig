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
const tri = @import("triangle.zig");
const mat = @import("matrix.zig");
const tex = @import("textures.zig");
const fb = @import("framebuffer.zig");
const tile = @import("tile.zig");
const Renderer = @import("renderer.zig");
const Scene = @import("scene.zig");

const GenRasterTrianglesJob = struct {
    wg: *std.Thread.WaitGroup,
    cube: *cube.Cube,
    view: mat.Mat4f,
    out: *std.ArrayList(tri.RasterTriangle),

    pub fn run(job: *GenRasterTrianglesJob) void {
        defer job.wg.finish();
        job.cube.genRasterTriangles(job.view, job.out);
    }
};

pub fn main() !void {
    @setFloatMode(.optimized);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });

    var renderer = try Renderer.Renderer.init(allocator);
    var scene = Scene.Scene.init();
    var gfx = try sdl_gfx.SdlGfx.init();
    var platform = sdl_platform.SdlPlatform.init();

    var tiles = tile.TilePool.init();

    ctx.projection_matrix = mat.create_projection_matrix();

    ctx.atlas = try tex.Atlas.init();

    var t: usize = 0;

    while (platform.running) : (t += 1) {
        try renderer.begin_frame(allocator);
        const dt = platform.begin_frame();

        var framebuffer = try gfx.begin_frame();

        const view: mat.Mat4f = mat.world_to_camera();

        var wg = std.Thread.WaitGroup{}; // used to wait for threads to finish

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var jobs = try arena_allocator.alloc(GenRasterTrianglesJob, scene.cubes.len);

        // Per cube output buffers
        var outs = try arena_allocator.alloc(std.ArrayList(tri.RasterTriangle), 3);
        for (outs) |*lst| lst.* = try std.ArrayList(tri.RasterTriangle).initCapacity(allocator, 6 * 2);

        for (&scene.cubes, 0..) |*cu, i| {
            wg.start();

            jobs[i] = .{
                .wg = &wg,
                .cube = cu,
                .view = view,
                .out = &outs[i],
            };

            try pool.spawn(GenRasterTrianglesJob.run, .{&jobs[i]});
        }

        wg.wait(); // ensure all jobs are finished

        // Merge results
        for (outs) |*lst| {
            renderer.triangles.appendSliceAssumeCapacity(lst.items);
        }

        if (cfg.show_tex_atlas) ctx.atlas.debug_show_atlas(&framebuffer);

        if (cfg.show_tiles) tiles.debug_show_tiles_border(framebuffer);

        try renderer.render(&pool, &tiles, framebuffer, allocator);

        gfx.end_frame();
        gfx.present();

        if (cfg.show_fps) platform.fps_counter_update();

        sdl_platform.update_camera_look();
        platform.process_inputs(dt);

        framebuffer.clear_black();
    }
}
