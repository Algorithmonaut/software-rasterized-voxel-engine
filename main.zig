const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const mat = @import("math/matrix.zig");

const Engine = @import("Engine.zig").Engine;
const Atlas = @import("Atlas.zig").Atlas;
const Camera = @import("Camera.zig").Camera;
const EngineConfig = @import("EngineConfig.zig").EngineConfig;
const Framebuffer = @import("Framebuffer.zig").Framebuffer;
const Renderer = @import("Renderer.zig").Renderer;
const Chunk = @import("Chunk.zig").Chunk;
const Profiler = @import("Profiler.zig").Profiler;
const chunk_mesher = @import("world/chunk-mesher.zig");

const engine_config = EngineConfig{
    .camera_config = .{
        .fov = 90.0,
        .view_distance = 300.0,
        .from = .{ 0, 40, -20 },
        .to = .{ 0, 40, -21 },
        // .speed = 1015.0,
        .speed = 15.0,
        .sensivity = 0.0025,
        // .near = 0.25,
        .near = 1,
    },
    .framebuffer_config = .{
        .width = 1920,
        .height = 1080,
        .scale = 1,
        .tile_dimensions = 16,
    },
    .atlas_config = .{
        .width = 96,
        .height = 48,
        .tex_w = 16,
        .tex_h = 16,
        .pixel_type = u32,
        .channels_rgb = 3,
    },
    .world_config = .{
        .chunk_size = 32,
    },
    .debug_config = .{
        .show_fps = true,
        .show_occupied_tiles = false,
        .show_tex_atlas = false,
    },
    .terrain_generator_config = .{
        .seed = 12345,
        .gain = 0.5,
        .lacunarity = 2.0,
        .octaves = 5,
        .scale = 0.005,

        .mountain_seed = 54321,
        .mountain_gain = 0.5,
        .mountain_lacunarity = 2.0,
        .mountain_octaves = 2,
        .mountain_scale = 0.002,
    },
};

var engine: Engine = undefined;

var main_prof = Profiler{};

var total_frame_ns: u64 = 0;

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

    try engine.world.bootstrapInitialChunks(
        allocator,
        engine.camera.from,
        engine.camera.view_distance,
        engine.terrain_generator,
    );

    var t: usize = 0;

    while (engine.platform.running) : (t += 1) {
        var frame_timer = try std.time.Timer.start();

        var frame = try engine.beginFrame();
        defer engine.endFrame(&frame);

        engine.camera.view_mat = mat.create_view(engine.camera.from, engine.camera.to);
        engine.camera.combined_mat = engine.camera.proj_mat.mul(engine.camera.view_mat);

        var prof_scope = try main_prof.begin(.triangle_setup);
        try engine.renderer.renderWorld(
            allocator,
            engine.camera.from,
            engine.world.chunk_size,
            &engine.world,
            &engine.camera,
            engine.terrain_generator,
        );
        prof_scope.end();

        prof_scope = try main_prof.begin(.tile_raster);
        try engine.triangle_rasterizer.render(
            allocator,
            &pool,
            engine.renderer.triangles.items,
            &engine.tile_pool,
            frame.framebuffer,
            &engine.atlas,
        );
        prof_scope.end();

        if (engine_config.debug_config.show_tex_atlas) engine.atlas.debug_show_atlas(&frame.framebuffer);
        if (engine_config.debug_config.show_occupied_tiles) engine.tile_pool.debug_show_tiles_border(frame.framebuffer);

        if (engine_config.debug_config.show_fps) engine.platform.fps_counter_update();

        engine.platform.process_inputs(frame.dt, &engine.camera, &engine.graphics, &engine.triangle_rasterizer);

        total_frame_ns += frame_timer.read();

        try engine.world.meshChunksBudgeted(allocator, 10);
    }

    main_prof.printReport(total_frame_ns);
}
