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

const Engine = @import("Engine.zig").Engine;
const Atlas = @import("Atlas.zig").Atlas;
const Camera = @import("Camera.zig").Camera;
const EngineConfig = @import("EngineConfig.zig").EngineConfig;
const Framebuffer = @import("Framebuffer.zig").Framebuffer;
const Renderer = @import("Renderer.zig").Renderer;
const cube_worker = @import("cube-worker.zig");
const Chunk = @import("Chunk.zig").Chunk;
const ChunkCoord = @import("Chunk.zig").ChunkCoord;

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
        .width = 960,
        .height = 540,
        .scale = 2,
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

    .world_config = .{
        .chunk_size = 8,
    },
};

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

    var t: usize = 0;

    const chunk1 = try engine.world.ensureChunk(.{ 0, 0, 0 });
    const chunk2 = try engine.world.ensureChunk(.{ 1, 0, 0 });

    while (engine.platform.running) : (t += 1) {
        var frame = try engine.beginFrame();
        defer engine.endFrame(&frame);

        engine.camera.view_mat = mat.create_view(engine.camera.from, engine.camera.to);

        try engine.renderer.renderChunk(allocator, chunk1, &engine.camera, &engine.atlas, pool);
        try engine.renderer.renderChunk(allocator, chunk2, &engine.camera, &engine.atlas, pool);

        try engine.renderer.render(&pool, &engine.tile_pool, frame.framebuffer, allocator, &engine.atlas);

        if (cfg.show_tex_atlas) engine.atlas.debug_show_atlas(&frame.framebuffer);
        if (cfg.show_tiles) engine.tile_pool.debug_show_tiles_border(frame.framebuffer);

        if (cfg.show_fps) engine.platform.fps_counter_update();

        engine.platform.process_inputs(frame.dt, &engine.camera, &engine.graphics);
    }
}
