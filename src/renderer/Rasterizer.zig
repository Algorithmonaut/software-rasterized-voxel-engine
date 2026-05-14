const std = @import("std");
const profiler_mod = @import("../profiler.zig");

const Tile = @import("../tile.zig").Tile;
const TilePool = @import("../tile.zig").TilePool;
const Framebuffer = @import("../Framebuffer.zig").Framebuffer;

const PrimitiveBuilder = @import("../PrimitiveBuilder.zig");
const ProjectedVertex = PrimitiveBuilder.ProjectedVertex;
const MaterialRef = PrimitiveBuilder.MaterialRef;
const PrimitiveRef = PrimitiveBuilder.PrimitiveRef;

const AtomicUsize = std.atomic.Value(usize);

const BATCH_SIZE: usize = 16;

const DEBUG_SINGLE_THREADED = @import("../main.zig").DEBUG_SINGLE_THREADED;

const rasterization = @import("rasterization.zig");

fn tileWorker(
    next: *AtomicUsize,
    tile_pool: *TilePool,
    buf: Framebuffer,
    tile_offsets: []const u32,
    tile_refs: []const u32,
    frame_primitives: []const PrimitiveRef,
    frame_materials: []const MaterialRef,
    frame_vertices: []const ProjectedVertex,
    sky_rows: []u32,
) void {
    while (true) {
        const tile_base = next.fetchAdd(BATCH_SIZE, .monotonic);
        if (tile_base >= tile_pool.count) break;

        const tile_batch_count = @min(BATCH_SIZE, tile_pool.count - tile_base);

        for (0..tile_batch_count) |incr| {
            const tile_i = tile_base + incr;

            const start = tile_offsets[tile_i];
            const end = tile_offsets[tile_i + 1];
            if (start == end) continue;

            var t = &tile_pool.tiles[tile_i];
            t.clearGradient(sky_rows);

            for (tile_refs[start..end]) |prim_i_u| {
                const prim_i: usize = @intCast(prim_i_u);
                if (prim_i >= frame_primitives.len)
                    std.debug.panic("prim_i out of range: {} / {}", .{ prim_i, frame_primitives.len });

                const prim = frame_primitives[prim_i];
                if (prim.vertex_count < 3 or prim.vertex_count > 9)
                    std.debug.panic("bad vertex_count: prim_i={}, count={}", .{ prim_i, prim.vertex_count });

                const vert_start: usize = @intCast(prim.base_vertex);
                const vert_end: usize = vert_start + @as(usize, @intCast(prim.vertex_count));
                if (vert_end > frame_vertices.len)
                    std.debug.panic(
                        "bad vertex slice: prim_i={}, base={}, count={}, end={}, verts_len={}",
                        .{ prim_i, prim.base_vertex, prim.vertex_count, vert_end, frame_vertices.len },
                    );

                if (prim.vertex_count == 4)
                    rasterization.renderQuadInTile(
                        frame_materials[prim_i],
                        frame_vertices[vert_start..vert_end],
                        t,
                        sky_rows,
                    )
                else
                    rasterization.renderPolygonInTile(
                        frame_materials[prim_i],
                        frame_vertices[vert_start..vert_end],
                        t,
                        sky_rows,
                    );
            }

            t.writeToFb(buf);
        }
    }
}

pub const Rasterizer = struct {
    render_wireframe: bool = false,
    render_linear_depth: bool = false,

    // TODO: Maybe change to u32
    tile_counts: []u32,
    tile_offsets: []u32,
    /// Per tile write cursor, same as tile_offsets before 2nd pass
    write_pos: []u32,
    /// For all tiles, holds the indices of the primitives that overlap
    tile_primitive_indices: []u32,

    pub fn init(allocator: std.mem.Allocator, tile_count: usize) !Rasterizer {
        return .{
            .tile_counts = try allocator.alloc(u32, tile_count),
            .tile_offsets = try allocator.alloc(u32, tile_count + 1),
            .write_pos = try allocator.alloc(u32, tile_count + 1),
            .tile_primitive_indices = try allocator.alloc(u32, 70_000),
        };
    }

    pub fn deinit(self: *Rasterizer, allocator: std.mem.Allocator) void {
        allocator.free(self.tile_counts);
        allocator.free(self.tile_offsets);
        allocator.free(self.write_pos);
        allocator.free(self.tile_primitive_indices);
    }

    inline fn ensureTileRefsCapacity(
        self: *Rasterizer,
        allocator: std.mem.Allocator,
        needed: usize,
    ) !void {
        if (self.tile_primitive_indices.len >= needed) return;

        const new_cap = @max(self.tile_primitive_indices.len * 2, needed);
        const new_buf = try allocator.alloc(u32, new_cap);
        allocator.free(self.tile_primitive_indices);
        self.tile_primitive_indices = new_buf;
    }

    pub fn render(
        self: *Rasterizer,
        allocator: std.mem.Allocator,
        tile_pool: *TilePool,
        fb: Framebuffer,
        frame_primitives: []const PrimitiveRef,
        frame_materials: []const MaterialRef,
        frame_vertices: []const ProjectedVertex,
        sky_rows: []u32,
        group: *std.Io.Group,
        io: std.Io,
        timings: ?*profiler_mod.RasterizerTimings,
    ) !void {
        var timer = profiler_mod.ProfTimer.start(io);

        @memset(self.tile_counts, 0);

        if (timings) |tm| tm.clear_ns = timer.lap();

        //// FIRST PASS | COUNT THE PRIMITIVES FOR EACH TILE ////
        for (frame_primitives) |prim| {
            for (prim.min_ty..prim.max_ty) |ty| {
                for (prim.min_tx..prim.max_tx) |tx| {
                    const idx = tx + tile_pool.count_w * ty;
                    const tile = &tile_pool.tiles[idx];
                    // if (!triangleOverlapTile(&prim, tile)) continue;
                    self.tile_counts[idx] += 1;
                    tile.was_occupied = true;
                }
            }
        }

        if (timings) |tm| tm.count_ns = timer.lap();

        var sum: u32 = 0;
        for (0..tile_pool.count) |t| {
            self.tile_offsets[t] = sum;
            sum += self.tile_counts[t];
        }
        self.tile_offsets[tile_pool.count] = sum;

        if (timings) |tm| tm.prefix_ns = timer.lap();

        try self.ensureTileRefsCapacity(allocator, sum);
        @memcpy(self.write_pos[0..], self.tile_offsets[0..]);

        if (timings) |tm| tm.ensure_refs_ns = timer.lap();

        //// SECOND PASS | SCATTER PRIMITIVE INDICES ////
        for (0..frame_primitives.len) |prim_i| {
            const prim = frame_primitives[prim_i];

            for (prim.min_ty..prim.max_ty) |ty| {
                for (prim.min_tx..prim.max_tx) |tx| {
                    const tile_i = tx + tile_pool.count_w * ty;
                    // if (!triangleOverlapTile(&prim, tile)) continue;
                    const dst = self.write_pos[tile_i];
                    self.tile_primitive_indices[dst] = @intCast(prim_i);
                    self.write_pos[tile_i] = dst + 1;
                }
            }
        }

        if (timings) |tm| tm.scatter_ns = timer.lap();

        //// THIRD PASS | RENDER TILES ////
        var next = AtomicUsize.init(0);

        if (DEBUG_SINGLE_THREADED) {
            tileWorker(
                &next,
                tile_pool,
                fb,
                self.tile_offsets,
                self.tile_primitive_indices,
                frame_primitives,
                frame_materials,
                frame_vertices,
                sky_rows,
            );
        } else {
            // TODO: Move this to engine and only set it once
            const worker_count = try std.Thread.getCpuCount();

            for (0..worker_count) |_| {
                group.async(io, tileWorker, .{
                    &next,
                    tile_pool,
                    fb,
                    self.tile_offsets,
                    self.tile_primitive_indices,
                    frame_primitives,
                    frame_materials,
                    frame_vertices,
                    sky_rows,
                });
            }

            try group.await(io);
        }

        if (timings) |tm| tm.tiles_ns = timer.lap();
    }
};
