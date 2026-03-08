const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const cfg = @import("config.zig");
const cube = @import("Cube.zig");
const ctx = @import("context.zig");
const tri = @import("triangle.zig");
const mat = @import("math/matrix.zig");
const Scene = @import("scene.zig");

const Engine = @import("Engine.zig").Engine;
const Atlas = @import("Atlas.zig").Atlas;
const Camera = @import("Camera.zig").Camera;
const EngineConfig = @import("./engine/EngineConfig.zig").EngineConfig;
const Framebuffer = @import("Framebuffer.zig").Framebuffer;
const Renderer = @import("Renderer.zig").Renderer;

const engine_config = EngineConfig{
    .camera_config = .{
        .fov = 90.0,
        .view_distance = 2000.0,
        .from = .{ 0, 0, 0 },
        .to = .{ 0, 0, 0 },
        .speed = 15.0,
        .sensivity = 0.0025,
    },

    .framebuffer_config = .{
        .width = 1920,
        .height = 1080,
        .scale = 1,
        .tile_dimensions = 8,
    },

    .atlas_config = .{
        .width = 96,
        .height = 48,
        .tex_w = 16,
        .tex_h = 16,
        .pixel_type = u32,
        .channels_rgb = 3,
    },
};

const PerCubeOut = cube.PerCubeOut;

const AtomicUsize = std.atomic.Value(usize);

fn cube_worker(
    next: *AtomicUsize,
    cubes: []cube.Cube,
    outs: []PerCubeOut,
) void {
    while (true) {
        const i = next.fetchAdd(1, .monotonic);
        if (i >= cubes.len) break;

        outs[i].len = cubes[i].genRasterTriangles(
            engine.renderer,
            &engine.camera,
            &engine.atlas,
            &outs[i].tris,
        );
    }
}

var engine: Engine = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    engine = try Engine.init(
        allocator, // Allocator
        engine_config,
    );
    @setFloatMode(.optimized);

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });

    var scene = try Scene.Scene.init(allocator);

    engine.camera.proj_mat = mat.create_projection_matrix(&engine.camera);

    var t: usize = 0;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const outs = try arena_allocator.alloc(PerCubeOut, scene.cubes.len);

    while (engine.platform.running) : (t += 1) {
        var frame = try engine.begin_frame();
        defer engine.end_frame(&frame);

        engine.camera.view_mat = mat.create_view(engine.camera.from, engine.camera.to);

        // generate raster triangles from cubes
        var next = AtomicUsize.init(0);
        var wg = std.Thread.WaitGroup{};
        const worker_count = try std.Thread.getCpuCount();

        @memset(outs, .{});

        for (0..worker_count) |_| {
            pool.spawnWg(&wg, cube_worker, .{ &next, scene.cubes[0..], outs });
        }
        wg.wait();

        // Merge results
        for (outs) |*lst| {
            const src = lst.tris[0..lst.len];
            engine.renderer.triangles.appendSliceAssumeCapacity(src);
        }

        try engine.renderer.render(&pool, &engine.tile_pool, frame.framebuffer, allocator, &engine.atlas);

        if (cfg.show_tex_atlas) engine.atlas.debug_show_atlas(&frame.framebuffer);
        if (cfg.show_tiles) engine.tile_pool.debug_show_tiles_border(frame.framebuffer);

        if (cfg.show_fps) engine.platform.fps_counter_update();

        engine.platform.process_inputs(frame.dt, &engine.camera, &engine.graphics);
    }
}
