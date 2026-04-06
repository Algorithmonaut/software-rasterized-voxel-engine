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

const engine_config = EngineConfig{
    .camera_config = .{
        .fov = 110.0,
        .view_distance = 300.0,
        .sensitivity = 0.0025,
        .near = 0.1,
    },
    .player_config = .{
        .initial_position = .{ 0.0, 100.0, 0.0 },
        .half_size = .{ 0.3, 0.9, 0.3 },
        .speed = 8.0,

        .air_accel = 20,
        .air_decel = 40,
        .ground_accel = 120,
        .ground_decel = 240,

        .gravity = 40,
        .jump_speed = 10,
    },

    .framebuffer_config = .{
        .width = 1920,
        .height = 1080,
        // .width = 1720,
        // .height = 720,
        // .width = 3440,
        // .height = 1440,
        .scale = 1,
        .tile_dimensions = 8,
    },
    .atlas_config = .{
        .width = 96,
        .height = 48 * 5,
        .tex_w = 16,
        .tex_h = 16,
    },
    .debug_config = .{
        .show_fps = true,
        .show_occupied_tiles = false,
        .show_tex_atlas = true,
    },
    .world_config = .{
        .seed = 12345,
        .gain = 0.5,
        .lacunarity = 2.0,
        .octaves = 5,
        .scale = 0.003,

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
    @setFloatMode(.optimized);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    engine = try Engine.init(
        allocator, // Allocator
        engine_config,
    );

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });

    var t: usize = 0;

    // try engine.world.bootstrapInitialChunks(
    //     allocator,
    //     .{ 0, -100, 0 },
    //     engine.player.camera.view_distance,
    //     &engine.terrain_generator,
    //     &engine.world,
    // );

    while (engine.platform.running) : (t += 1) {
        var frame_timer = try std.time.Timer.start();

        var frame = try engine.beginFrame();
        defer engine.endFrame(&frame);

        engine.platform.process_inputs(
            frame.dt,
            &engine.player,
            &engine.graphics,
            &engine.triangle_rasterizer,
        );

        try engine.player.update(&engine.world);

        engine.player.camera.view_mat = mat.create_view(
            engine.player.camera.from,
            engine.player.camera.to,
        );
        engine.player.camera.combined_mat = engine.player.camera.proj_mat.mul(
            engine.player.camera.view_mat,
        );

        var prof_scope = try main_prof.begin(.triangle_setup);
        try engine.renderer.renderWorld(
            allocator,
            engine.player.camera.from,
            engine.world.chunk_size,
            &engine.world,
            &engine.player.camera,
            &engine.terrain_generator,
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

        total_frame_ns += frame_timer.read();

        try engine.world.meshChunks(allocator, engine.mesher);
    }

    main_prof.printReport(total_frame_ns);
}
