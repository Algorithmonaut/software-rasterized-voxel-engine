const cube = @import("Cube.zig");
const std = @import("std");
const Engine = @import("Engine.zig").Engine;

const Scene = @import("scene.zig").Scene;
const RasterTriangle = @import("triangle.zig").RasterTriangle;

const Camera = @import("Camera.zig").Camera;
const Atlas = @import("Atlas.zig").Atlas;

const Renderer = @import("Renderer.zig");

const AtomicUsize = std.atomic.Value(usize);

/// Helps avoid ping pong of the atomic between cores
const batch_size: usize = 8;

fn cube_worker(
    next_batch: *AtomicUsize,
    cubes: []cube.Cube,
    outs: []RasterTriangle,
    outs_count: []usize,
    renderer: *Renderer.Renderer,
    camera: *Camera,
    atlas: *Atlas,
) void {
    while (true) {
        const cube_base: usize = next_batch.fetchAdd(batch_size, .monotonic);
        if (cube_base >= cubes.len) break;

        inline for (0..batch_size) |incr| {
            const cube_i = cube_base + incr;
            if (cube_i >= cubes.len) break;

            const outs_base = cube_i * 12;
            outs_count[cube_i] = cubes[cube_i].genRasterTriangles(
                renderer,
                camera,
                atlas,
                outs[outs_base .. outs_base + 12],
            );
        }
    }
}

pub fn render_all(
    allocator: std.mem.Allocator,
    engine: *Engine,
    scene: *Scene,
    pool: *std.Thread.Pool,
) !void {
    _ = allocator;
    var next_batch = AtomicUsize.init(0);

    var wg = std.Thread.WaitGroup{};
    const worker_count = try std.Thread.getCpuCount();

    for (0..worker_count) |_| {
        pool.spawnWg(&wg, cube_worker, .{
            &next_batch,
            scene.cubes[0..],
            engine.renderer.triangles,
            engine.renderer.cubes_triangles_count,
            &engine.renderer,
            &engine.camera,
            &engine.atlas,
        });
    }
    wg.wait();
}
