const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const mat = @import("math/matrix.zig");

const Engine = @import("Engine.zig").Engine;
const Atlas = @import("Atlas.zig").Atlas;
const Camera = @import("game/Camera.zig").Camera;
const EngineConfig = @import("EngineConfig.zig").EngineConfig;
const Framebuffer = @import("Framebuffer.zig").Framebuffer;
const Renderer = @import("Renderer.zig").Renderer;
const renderer = @import("Renderer.zig");
const DebugOverlay = @import("UI/DebugOverlay.zig").DebugOverlay;

const CHUNK_SIZE = @import("world/Chunk.zig").CHUNK_SIZE;

pub const DEBUG_SINGLE_THREADED = false;

pub const ENABLE_DEBUG_OVERLAY = true;
pub var debug_overlay = DebugOverlay{};

const engine_config = EngineConfig{
    .camera_config = .{
        .fov = 90.0,
        .view_distance = 800.0,
        .sensitivity = 0.0025,
        .near = 0.1,
    },
    .player_config = .{
        .initial_position = .{ 0.0, 300.0, 0.0 },
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
        .scale = 1,
        .tile_dimensions = 8, // as John Ousterhout said, voo-doo constants
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
        .show_tex_atlas = false,
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

        .min_world_y = -192,
        .max_world_y = 320,

        .bootstrap_radius_chunk = 20,
        .collision_radius_chunks = 3,
        .gen_budget_per_tick = 5,
        .mesh_budget_per_tick = 5,
        .render_radius_chunks = 20,
    },
};

var engine: Engine = undefined;
var total_frame_ns: u64 = 0;

pub fn main() !void {
    @setFloatMode(.optimized);

    // var debug_allocator = std.heap.DebugAllocator(.{}){};
    // defer std.debug.assert(debug_allocator.deinit() == .ok);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var ts = std.heap.ThreadSafeAllocator{
        .child_allocator = gpa.allocator(),
    };
    const allocator = ts.allocator();

    engine = try Engine.init(
        allocator,
        engine_config,
    );

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });

    try engine.chunk_manager.bootstrapInitialChunks(
        allocator,
        &engine.world,
        engine.terrain_generator,
    );

    var t: usize = 0;

    while (engine.platform.running) : (t += 1) {
        try engine.chunk_manager.drainWorkerResults(allocator, &engine.world, engine.chunk_worker);

        var frame_timer = try std.time.Timer.start();

        var frame = try engine.beginFrame();
        defer engine.endFrame(&frame);

        engine.platform.process_inputs(
            frame.dt,
            &engine.player,
            &engine.graphics,
        );

        try engine.player.update(&engine.world);

        engine.player.camera.view_mat = mat.create_view(
            engine.player.camera.from,
            engine.player.camera.to,
        );

        engine.player.camera.combined_mat = engine.player.camera.proj_mat.mul(
            engine.player.camera.view_mat,
        );

        try engine.chunk_manager.updateChunks(
            allocator,
            &engine.world,
            engine.chunk_worker,
            engine.player.camera.from,
        );

        const visible_chunks = engine.chunk_manager.getVisibleActiveChunks(
            engine.player.camera.combined_mat,
        );

        for (visible_chunks) |slot|
            try renderer.generatePrimitivesFromChunk(
                &engine.renderer,
                slot,
                engine.player.camera.from,
                engine.player.camera.combined_mat,
            );

        if (ENABLE_DEBUG_OVERLAY) {
            for (engine.renderer.frame_primitives.items) |prim| {
                debug_overlay.triangles_after_clipping += prim.vertex_count - 2;
            }

            debug_overlay.player_pos = engine.player.camera.from;
            debug_overlay.player_vel = engine.player.velocity;
            debug_overlay.player_grounded = engine.player.grounded;
        }

        try engine.rasterizer.render(
            allocator,
            &pool,
            &engine.tile_pool,
            frame.framebuffer,
            &engine.atlas,
            engine.renderer.frame_primitives.items,
            engine.renderer.frame_materials.items,
            engine.renderer.frame_vertices.items,
        );

        try debug_overlay.render(&engine.text, &frame.framebuffer);
        debug_overlay.renderGizmo(&frame.framebuffer, engine.player.camera.from, engine.player.camera.to);
        debug_overlay.frameReset();

        if (engine_config.debug_config.show_tex_atlas) engine.atlas.debug_show_atlas(&frame.framebuffer);
        if (engine_config.debug_config.show_occupied_tiles) engine.tile_pool.debug_show_tiles_border(frame.framebuffer);

        if (engine_config.debug_config.show_fps) engine.platform.fps_counter_update();

        total_frame_ns += frame_timer.read();
    }
}
