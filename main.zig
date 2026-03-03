const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const cfg = @import("config.zig");
const cube = @import("cube.zig");
const ctx = @import("context.zig");
const tri = @import("triangle.zig");
const mat = @import("matrix.zig");
const tex = @import("textures.zig");
const Scene = @import("scene.zig");

const Engine = @import("Engine.zig");

const EngineConfig = @import("./engine/EngineConfig.zig").EngineConfig;

const engine_config = EngineConfig{
    .camera_config = .{
        .fov = 90.0,
        .view_distance = 200.0,
        .from = .{ 0, 0, 0 },
        .to = .{ 0, 0, 0 },
        .speed = 40.0,
    },
    .framebuffer_config = .{
        .width = 960,
        .height = 540,
        .scale = 2,
        .tile_dimensions = 32,
    },
};

const PerCubeOut = cube.PerCubeOut;

var engine: Engine.Engine = undefined;

const GenRasterTrianglesJob = struct {
    wg: *std.Thread.WaitGroup,
    cube: *cube.Cube,
    view: mat.Mat4f,
    out: *PerCubeOut,

    pub fn run(job: *GenRasterTrianglesJob) void {
        defer job.wg.finish();
        job.cube.genRasterTriangles(engine.renderer, job.view, job.out);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    engine = try Engine.Engine.init(
        allocator, // Allocator
        engine_config,
    );
    @setFloatMode(.optimized);

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });

    var scene = Scene.Scene.init();

    ctx.projection_matrix = mat.create_projection_matrix(&engine.camera);

    ctx.atlas = try tex.Atlas.init();

    var t: usize = 0;

    while (engine.platform.running) : (t += 1) {
        var frame = try engine.begin_frame();
        defer engine.end_frame(&frame);

        const view: mat.Mat4f = mat.create_view(engine.camera.from, engine.camera.to);

        var wg = std.Thread.WaitGroup{}; // used to wait for threads to finish

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var jobs = try arena_allocator.alloc(GenRasterTrianglesJob, scene.cubes.len);

        // Per cube output buffers
        var outs = try arena_allocator.alloc(PerCubeOut, scene.cubes.len);
        @memset(outs, .{});

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
            const src = lst.tris[0..lst.len];
            engine.renderer.triangles.appendSliceAssumeCapacity(src);
        }

        try engine.renderer.render(&pool, &engine.tile_pool, frame.framebuffer, allocator);

        if (cfg.show_tex_atlas) ctx.atlas.debug_show_atlas(&frame.framebuffer);
        if (cfg.show_tiles) engine.tile_pool.debug_show_tiles_border(frame.framebuffer);

        if (cfg.show_fps) engine.platform.fps_counter_update();

        engine.platform.process_inputs(frame.dt, &engine.camera);
    }
}
