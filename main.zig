const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const cfg = @import("config.zig");
const sdl_gfx = @import("sdl-graphics.zig");
const cube = @import("cube.zig");
const ctx = @import("context.zig");
const tri = @import("triangle.zig");
const mat = @import("matrix.zig");
const tex = @import("textures.zig");
const fb = @import("framebuffer.zig");
const tile = @import("tile.zig");
const Scene = @import("scene.zig");

const Engine = @import("Engine.zig");

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var engine = Engine.Engine.init(
        allocator, // Allocator
        .{ 0, 0, 0 }, //Camera from
        .{ 0, 0, 0 }, // Camera to
    );
    @setFloatMode(.optimized);

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });

    var scene = Scene.Scene.init();
    var gfx = try sdl_gfx.SdlGfx.init();

    var tiles = try tile.TilePool.init(allocator);

    ctx.projection_matrix = mat.create_projection_matrix();

    ctx.atlas = try tex.Atlas.init();

    var t: usize = 0;

    while (engine.platform.running) : (t += 1) {
        const frame = try engine.begin_frame();
        var framebuffer = try gfx.begin_frame();
        defer gfx.end_frame();

        framebuffer.clear_black();

        const view: mat.Mat4f = mat.create_view(engine.camera.from, engine.camera.to);

        var wg = std.Thread.WaitGroup{}; // used to wait for threads to finish

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var jobs = try arena_allocator.alloc(GenRasterTrianglesJob, scene.cubes.len);

        // Per cube output buffers
        var outs = try arena_allocator.alloc(std.ArrayList(tri.RasterTriangle), 100);
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
            engine.renderer.triangles.appendSliceAssumeCapacity(lst.items);
        }

        if (cfg.show_tex_atlas) ctx.atlas.debug_show_atlas(&framebuffer);

        if (cfg.show_tiles) tiles.debug_show_tiles_border(framebuffer);

        try engine.renderer.render(&pool, &tiles, framebuffer, allocator);

        gfx.present();

        if (cfg.show_fps) engine.platform.fps_counter_update();

        engine.platform.process_inputs(frame.dt, &engine.camera);
    }
}
