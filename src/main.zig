const std = @import("std");
const mat = @import("math/matrix.zig");
const renderer = @import("Renderer.zig");
const constants = @import("constants.zig");
const sky_gradient = @import("sky-gradient.zig");
const helpers = @import("helpers.zig");
const textures = @import("assets/textures.zig");
const overlay = @import("UI/overlay.zig");
const profiler_mod = @import("profiler.zig");

const Engine = @import("Engine.zig").Engine;
const Framebuffer = @import("Framebuffer.zig").Framebuffer;
const EngineConfig = @import("EngineConfig.zig").EngineConfig;
const DebugOverlay = @import("UI/DebugOverlay.zig").DebugOverlay;

pub const DEBUG_SINGLE_THREADED = false;
const CHUNK_SIZE = constants.CHUNK_SIZE;

pub const ENABLE_DEBUG_OVERLAY = true;
pub var debug_overlay = DebugOverlay{};

var profiler = profiler_mod.RollingProfiler{};

const engine_config = EngineConfig{
    .camera_config = .{
        .fov = 90.0,
        .view_distance = 800.0,
        .sensitivity = 0.0025,
        .near = 0.01,
    },
    .player_config = .{
        .initial_position = .{ 0.0, 300.0, 0.0 },
        .half_size = .{ 0.3, 0.905, 0.3 },
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

pub fn main(init: std.process.Init) !void {
    @setFloatMode(.optimized);

    var allocator = std.heap.smp_allocator;

    engine = try Engine.init(allocator, engine_config, init.io);

    const sky_rows = try allocator.alloc(u32, engine_config.framebuffer_config.height);
    defer allocator.free(sky_rows);

    var group: std.Io.Group = .init;
    defer group.cancel(init.io);

    try engine.chunk_manager.bootstrapInitialChunks(
        allocator,
        &engine.world,
        engine.terrain_generator,
    );

    {
        const cfg = engine_config.world_config;

        var y: i32 = @intCast(cfg.max_world_y - 1);
        const min_y: i32 = @intCast(cfg.min_world_y);

        while (y >= min_y) : (y -= 1) {
            const block = engine.world.getBlockIdFromWorldCoordinates(.{ 0, y, 0 });

            if (block != .air and block != .unknown) {
                engine.player.position = .{
                    0.5,
                    @as(f32, @floatFromInt(y)) + 1.001,
                    0.5,
                };
                break;
            }
        }
    }

    engine.platform.resetFrameClock();

    var t: usize = 0;
    while (engine.platform.running) : (t += 1) {
        var timer = profiler_mod.ProfTimer.start(init.io);
        var timings = profiler_mod.FrameTimings{};

        try engine.chunk_manager.drainWorkerResults(
            allocator,
            &engine.world,
            engine.chunk_worker,
        );
        timings.drain_chunks_ns = timer.lap();

        var frame = try engine.beginFrame(sky_rows);
        timings.begin_frame_ns = timer.lap();

        const frame_inputs = engine.platform.processInputs(frame.dt);
        timings.input_ns = timer.lap();

        try engine.player.update(
            &engine.world,
            engine.chunk_worker,
            &engine.chunk_manager,
            &frame_inputs,
            allocator,
        );
        timings.player_update_ns = timer.lap();

        sky_gradient.buildSkyRowsForCamera(sky_rows, &engine.player.camera);
        timings.sky_ns = timer.lap();

        try engine.chunk_manager.updateChunks(
            allocator,
            &engine.world,
            engine.chunk_worker,
            engine.player.camera.from,
            false,
        );
        timings.update_chunks_ns = timer.lap();

        const visible_chunks = engine.chunk_manager.getVisibleActiveChunks(
            engine.player.camera.combined_mat,
        );
        timings.visible_chunks_ns = timer.lap();
        timings.visible_chunks = visible_chunks.len;

        try engine.primitive_builder.buildPrimitives(
            visible_chunks,
            engine.player.camera.from,
            engine.player.camera.combined_mat,
            allocator,
            &group,
            init.io,
        );

        timings.primitive_build_ns = timer.lap();

        timings.primitives = engine.primitive_builder.frame_primitives.items.len;
        timings.vertices = engine.primitive_builder.frame_vertices.items.len;

        if (ENABLE_DEBUG_OVERLAY) {
            for (engine.primitive_builder.frame_primitives.items) |prim| {
                debug_overlay.triangles_after_clipping += prim.vertex_count - 2;
            }

            debug_overlay.player_pos = engine.player.camera.from;
            debug_overlay.player_vel = engine.player.velocity;
            debug_overlay.player_grounded = engine.player.grounded;
        }

        timings.debug_overlay_ns = timer.lap();

        try engine.rasterizer.render(
            allocator,
            &engine.tile_pool,
            frame.framebuffer,
            engine.primitive_builder.frame_primitives.items,
            engine.primitive_builder.frame_materials.items,
            engine.primitive_builder.frame_vertices.items,
            sky_rows,
            &group,
            init.io,
            &timings.rasterizer,
        );

        _ = timer.lap();

        timings.tile_refs = engine.rasterizer.tile_offsets[engine.tile_pool.count];

        try debug_overlay.render(&frame.framebuffer);
        debug_overlay.renderGizmo(
            &frame.framebuffer,
            engine.player.camera.from,
            engine.player.camera.to,
        );
        debug_overlay.frameReset();

        // Draw the crosshair
        const size: usize = 16;
        const pixel_center =
            @Vector(2, usize){ frame.framebuffer.width / 2, frame.framebuffer.height / 2 };

        for (pixel_center[0] - size..pixel_center[0] + size) |x| {
            frame.framebuffer.set_pixel_blend(x, pixel_center[1], 0xA0FFFFFF);
            frame.framebuffer.set_pixel_blend(x, pixel_center[1] - 1, 0xA0FFFFFF);
            frame.framebuffer.set_pixel_blend(x, pixel_center[1] + 1, 0xA0FFFFFF);
        }

        for (pixel_center[1] - size..pixel_center[1] + size) |y| {
            frame.framebuffer.set_pixel_blend(pixel_center[0], y, 0xA0FFFFFF);
            frame.framebuffer.set_pixel_blend(pixel_center[0] - 1, y, 0xA0FFFFFF);
            frame.framebuffer.set_pixel_blend(pixel_center[0] + 1, y, 0xA0FFFFFF);
        }

        overlay.drawBlockSelector(&frame.framebuffer, engine.player.selected_block);

        timings.overlay_render_ns = timer.lap();

        engine.endFrame(&frame);

        timings.end_frame_ns = timer.lap();

        timings.frame_ns =
            timings.drain_chunks_ns +
            timings.begin_frame_ns +
            timings.input_ns +
            timings.player_update_ns +
            timings.camera_ns +
            timings.sky_ns +
            timings.update_chunks_ns +
            timings.visible_chunks_ns +
            timings.primitive_build_ns +
            timings.debug_overlay_ns +
            timings.rasterizer.total() +
            timings.overlay_render_ns +
            timings.end_frame_ns;

        profiler.push(timings);
    }
}
