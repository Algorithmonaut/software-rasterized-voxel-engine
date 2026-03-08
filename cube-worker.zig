const cube = @import("Cube.zig");
const std = @import("std");
const Engine = @import("Engine.zig").Engine;

const PerCubeOut = cube.PerCubeOut;
const Scene = @import("scene.zig").Scene;
const RasterTriangle = @import("triangle.zig").RasterTriangle;

const Renderer = @import("Renderer.zig");

const AtomicUsize = std.atomic.Value(usize);

/// Space reserved in the final triangle array for each worker (incremental)
const default_tri_block_cap: usize = 256;

const WorkerSpanList = std.ArrayListUnmanaged(Renderer.TriSpan);

fn cube_worker(
    next: *AtomicUsize,
    tri_cursor: *AtomicUsize,
    cubes: []cube.Cube,
    outs: []RasterTriangle,
    spans: *WorkerSpanList,
    allocator: std.mem.Allocator,
    engine: *Engine,
) void {
    var block_base: usize = tri_cursor.fetchAdd(default_tri_block_cap, .monotonic);
    var block_used: usize = 0;

    while (true) {
        const i = next.fetchAdd(1, .monotonic);
        if (i >= cubes.len) break;

        if (block_used + 12 > default_tri_block_cap) {
            if (block_used != 0) {
                spans.append(allocator, .{
                    .start = @intCast(block_base),
                    .len = @intCast(block_used),
                }) catch unreachable;
            }
            block_base = tri_cursor.fetchAdd(default_tri_block_cap, .monotonic);
            block_used = 0;
        }

        const idx = block_base + block_used;

        const n = cubes[i].genRasterTriangles(
            engine.renderer,
            &engine.camera,
            &engine.atlas,
            outs[idx .. idx + 12],
        );

        block_used += n;
    }

    if (block_used != 0) {
        spans.append(allocator, .{
            .start = @intCast(block_base),
            .len = @intCast(block_used),
        }) catch unreachable;
    }
}

pub fn render_all(
    allocator: std.mem.Allocator,
    engine: *Engine,
    scene: *Scene,
    pool: *std.Thread.Pool,
) !void {
    var next = AtomicUsize.init(0);
    var tri_cursor = AtomicUsize.init(0);

    var wg = std.Thread.WaitGroup{};
    const worker_count = try std.Thread.getCpuCount();
    const worker_spans = try allocator.alloc(WorkerSpanList, worker_count);

    for (worker_spans) |*lst| {
        lst.* = .{};
        try lst.ensureTotalCapacity(allocator, 32);
    }

    for (0..worker_count) |i| {
        pool.spawnWg(&wg, cube_worker, .{
            &next,
            &tri_cursor,
            scene.cubes[0..],
            engine.renderer.triangles,
            &worker_spans[i],
            allocator,
            engine,
        });
    }
    wg.wait();

    var total_spans: usize = 0;
    for (worker_spans) |*lst| {
        total_spans += lst.items.len;
    }

    try engine.renderer.tri_spans.ensureTotalCapacity(allocator, total_spans);
    engine.renderer.tri_spans.clearRetainingCapacity();

    for (worker_spans) |*lst| {
        engine.renderer.tri_spans.appendSliceAssumeCapacity(lst.items);
    }
}
