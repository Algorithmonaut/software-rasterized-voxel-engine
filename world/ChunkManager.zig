const std = @import("std");
const types = @import("../math/types.zig");
const mesher = @import("../mesh/mesher.zig");
const main = @import("../main.zig");

const F4 = types.Vec4f;
const F3 = types.Vec3f;
const ChunkCoord = types.ChunkCoord;
const WorldCoord = types.WorldCoord;
const World = @import("World.zig").World;
const ChunkSliceCoord = types.ChunkSliceCoord;
const ChunkSlot = @import("Chunk.zig").ChunkSlot;
const Mat4f = @import("../math/matrix.zig").Mat4f;
const ChunkVersion = @import("Chunk.zig").ChunkVersion;
const ChunkWorker = @import("ChunkWorker.zig").ChunkWorker;
const MeshResult = @import("../mesh/mesher.zig").MeshResult;
const DebugOverlay = @import("../UI/DebugOverlay.zig").DebugOverlay;
const TerrainGenerator = @import("TerrainGenerator.zig").TerrainGenerator;
const GenerationResult = @import("TerrainGenerator.zig").GenerationResult;

const DEBUG_SINGLE_THREADED = @import("../main.zig").DEBUG_SINGLE_THREADED;
const CHUNK_SIZE = @import("Chunk.zig").CHUNK_SIZE;
const VOXEL_COUNT = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;
const BATCH_SIZE = 16;

pub const AtomicUsize = std.atomic.Value(usize);

//// HELPERS ///////////////////////////////////////////////////////////////////

fn chunkCountInSphericalSegment(
    radius_world_in: f32,
    min_world_y: f32,
    max_world_y: f32,
) usize {
    const chunk_size_f: f32 = @floatFromInt(CHUNK_SIZE);
    const radius_chunks: i32 =
        @intFromFloat(@ceil(radius_world_in / chunk_size_f));

    const min_chunk_y: i32 = @intFromFloat(@floor(min_world_y / chunk_size_f));
    const max_chunk_y: i32 = @intFromFloat(@ceil(max_world_y / chunk_size_f));

    var acc: usize = 0;

    var z: i32 = -radius_chunks;
    while (z <= radius_chunks) : (z += 1) {
        var y: i32 = min_chunk_y;
        while (y <= max_chunk_y) : (y += 1) {
            var x: i32 = -radius_chunks;
            while (x <= radius_chunks) : (x += 1) {
                const r: i64 = radius_chunks;
                if (x * x + y * y + z * z <= r * r)
                    acc += 1;
            }
        }
    }

    return acc;
}

pub fn worldToChunkCoord(coord: WorldCoord) ChunkCoord {
    return .{
        @divFloor(@as(i32, @intFromFloat(@floor(coord[0]))), CHUNK_SIZE),
        @divFloor(@as(i32, @intFromFloat(@floor(coord[1]))), CHUNK_SIZE),
        @divFloor(@as(i32, @intFromFloat(@floor(coord[2]))), CHUNK_SIZE),
    };
}

pub fn dist2ToPlayer(player_coord: WorldCoord, slot: *const ChunkSlot) f32 {
    // Find chunk center
    const world_min: F3 = @floatFromInt(slot.world_min);
    const world_max: F3 = @floatFromInt(slot.world_max);
    const center = (world_min + world_max) * @as(F3, @splat(0.5));

    const d = center - player_coord;
    return d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
}

//// CHUNK BOOTSTRAPPING WORKERS ///////////////////////////////////////////////

fn generationWorker(
    next: *AtomicUsize,
    total: usize,
    allocator: std.mem.Allocator,
    chunk_slice_coords: []ChunkSliceCoord,
    world: *World,
    terrain_generator: *TerrainGenerator,
) void {
    while (true) {
        const base = next.fetchAdd(BATCH_SIZE, .monotonic);
        if (base >= chunk_slice_coords.len) break;
        std.debug.print("\x1b[2J\x1b[H", .{});
        std.debug.print("GENERATING, REMAINING: {}\n", .{total - base});

        for (0..BATCH_SIZE) |incr| {
            const chunk_slice_i = base + incr;
            if (chunk_slice_i >= chunk_slice_coords.len) break;
            const coord = chunk_slice_coords[chunk_slice_i];

            const results = terrain_generator.fillChunkSliceVoxels(
                allocator,
                coord,
            ) catch |err| {
                std.debug.panic("fillChunkVoxels failed: {s}", .{@errorName(err)});
            };
            defer allocator.free(results);

            for (results) |result|
                world.publishGenerationResult(allocator, world, result) catch |err| {
                    std.debug.panic("fillChunkVoxels failed: {s}", .{@errorName(err)});
                };
        }
    }
}

fn meshingWorker(
    next: *AtomicUsize,
    total: usize,
    allocator: std.mem.Allocator,
    chunk_coords: []ChunkCoord,
    world: *World,
) void {
    while (true) {
        const base = next.fetchAdd(BATCH_SIZE, .monotonic);
        if (base >= chunk_coords.len) break;
        std.debug.print("\x1b[2J\x1b[H", .{});
        std.debug.print("MESHING, REMAINING: {}\n", .{total - base});

        for (0..BATCH_SIZE) |incr| {
            const chunk_coord_i = base + incr;
            if (chunk_coord_i >= chunk_coords.len) break;
            const coord = chunk_coords[chunk_coord_i];

            const job = mesher.makeMeshJob(world, coord) orelse
                std.debug.panic("makeMeshJob returned null for {any}", .{coord});
            defer job.deinit(allocator);

            const result = mesher.processMeshJob(allocator, job) catch |err| {
                std.debug.panic("generateMesh failed for {any}: {s}", .{ coord, @errorName(err) });
            };

            world.publishMeshResult(allocator, result) catch |err| {
                std.debug.panic("generateMesh failed: {s}", .{@errorName(err)});
            };
        }
    }
}

//// MAIN //////////////////////////////////////////////////////////////////////

pub const ChunkManager = struct {
    pub const ChunkRenderEntry = struct { slot: *ChunkSlot, dist2: f32 };

    chunk_render_distance: i32,
    chunk_load_distance: i32,

    /// Inclusive
    chunk_min_y: i32,
    /// Exclusive
    chunk_max_y: i32,

    loaded: std.ArrayList(*ChunkSlot),
    loaded_count: usize,
    loaded_count_2d: usize,

    /// Chunks that are in view distance
    active: std.ArrayList(ChunkRenderEntry),
    active_count: usize,

    /// Chunks that are visible in the view frustum (computed per frame)
    visible: std.ArrayList(*ChunkSlot),

    // Force loaded/active to be recreated on first frame
    last_player_chunk: ChunkCoord = .{ 1000, 0, 0 },

    pub fn init(
        allocator: std.mem.Allocator,
        render_distance: f32,
        load_distance: f32,
        min_world_y: f32,
        max_world_y: f32,
    ) !ChunkManager {
        const loaded_count = chunkCountInSphericalSegment(load_distance, min_world_y, max_world_y);
        const loaded_count_2d = chunkCountInSphericalSegment(load_distance, 0, 0);
        const active_count = chunkCountInSphericalSegment(render_distance, min_world_y, max_world_y);

        const chunk_size_f: f32 = @floatFromInt(CHUNK_SIZE);

        const chunk_render_distance: i32 = @intFromFloat(@ceil(render_distance / chunk_size_f));
        const chunk_load_distance: i32 = @intFromFloat(@ceil(load_distance / chunk_size_f));
        const chunk_min_y: i32 = @intFromFloat(@floor(min_world_y / chunk_size_f));
        const chunk_max_y: i32 = @intFromFloat(@ceil(max_world_y / chunk_size_f));

        return .{
            .chunk_render_distance = chunk_render_distance,
            .chunk_load_distance = chunk_load_distance,

            .chunk_min_y = chunk_min_y,
            .chunk_max_y = chunk_max_y,

            .loaded = try std.ArrayList(*ChunkSlot).initCapacity(allocator, loaded_count),
            .loaded_count = loaded_count,
            .loaded_count_2d = loaded_count_2d,

            .active = try std.ArrayList(ChunkRenderEntry).initCapacity(allocator, active_count),
            .active_count = active_count,

            .visible = try std.ArrayList(*ChunkSlot).initCapacity(allocator, active_count),
        };
    }

    pub fn bootstrapInitialChunks(
        self: *ChunkManager,
        allocator: std.mem.Allocator,
        world: *World,
        terrain_generator: *TerrainGenerator,
    ) !void {
        const count = self.loaded_count;
        const slice_count = self.loaded_count_2d;

        var chunk_coords = try std.ArrayList(ChunkCoord).initCapacity(allocator, count);
        defer chunk_coords.deinit(allocator);

        var chunk_slice_coords = try std.ArrayList(ChunkSliceCoord).initCapacity(allocator, slice_count);
        defer chunk_slice_coords.deinit(allocator);

        var cz = -self.chunk_load_distance;
        while (cz <= self.chunk_load_distance) : (cz += 1) {
            var cx = -self.chunk_load_distance;
            while (cx <= self.chunk_load_distance) : (cx += 1) {
                if (cx * cx + cz * cz >
                    self.chunk_load_distance * self.chunk_load_distance) continue;

                chunk_slice_coords.appendAssumeCapacity(.{ cx, cz });

                var cy = self.chunk_min_y;
                while (cy < self.chunk_max_y) : (cy += 1) {
                    const coord = ChunkCoord{ cx, cy, cz };
                    chunk_coords.appendAssumeCapacity(coord);
                    _ = try world.getOrPutChunkSlot(allocator, coord);
                }
            }
        }

        var next = AtomicUsize.init(0);

        if (DEBUG_SINGLE_THREADED) {
            generationWorker(
                &next,
                slice_count,
                allocator,
                chunk_slice_coords.items,
                world,
                terrain_generator,
            );

            next.store(0, .monotonic);
            meshingWorker(
                &next,
                count,
                allocator,
                chunk_coords.items,
                world,
            );
            return;
        }

        const worker_count = try std.Thread.getCpuCount();

        var threads = try allocator.alloc(std.Thread, worker_count);
        defer allocator.free(threads);

        var spawned: usize = 0;

        // generation
        for (0..worker_count) |i| {
            threads[i] = try std.Thread.spawn(.{}, generationWorker, .{
                &next,
                slice_count,
                allocator,
                chunk_slice_coords.items,
                world,
                terrain_generator,
            });
            spawned += 1;
        }

        for (threads[0..spawned]) |t| t.join();

        // meshing
        next.store(0, .monotonic);
        spawned = 0;
        for (0..worker_count) |i| {
            threads[i] = try std.Thread.spawn(.{}, meshingWorker, .{
                &next,
                count,
                allocator,
                chunk_coords.items,
                world,
            });
            spawned += 1;
        }

        for (threads[0..spawned]) |t| t.join();
    }

    fn submitSliceGenerationJob(
        self: *ChunkManager,
        allocator: std.mem.Allocator,
        world: *World,
        chunk_worker: *ChunkWorker,
        slice_coord: ChunkSliceCoord,
    ) !void {
        try chunk_worker.submitGenerationJob(slice_coord);

        var cy = self.chunk_min_y;
        while (cy < self.chunk_max_y) : (cy += 1) {
            const coord = ChunkCoord{ slice_coord[0], cy, slice_coord[1] };
            const slot = try world.getOrPutChunkSlot(allocator, coord);
            if (slot.state == .absent) slot.state = .generating;
        }
    }

    /// Will run only if player's chunk has changed
    pub fn updateChunks(
        self: *ChunkManager,
        allocator: std.mem.Allocator,
        world: *World,
        chunk_worker: *ChunkWorker,
        player_pos: F3,
    ) !void {
        const player_chunk = worldToChunkCoord(player_pos);
        // if (@reduce(.And, player_chunk == self.last_player_chunk)) return;
        self.last_player_chunk = player_chunk;

        for (self.loaded.items) |chunk| {
            if (chunk.edited) continue;

            const dx = chunk.coord[0] - player_chunk[0];
            const dz = chunk.coord[2] - player_chunk[2];

            if (dx * dx + dz * dz > self.chunk_load_distance * self.chunk_load_distance)
                world.removeChunkSlot(allocator, chunk.coord);
        }

        self.loaded.clearRetainingCapacity();
        self.active.clearRetainingCapacity();

        var generating_counter: usize = 0;
        var meshing_counter: usize = 0;

        var cz = player_chunk[2] - self.chunk_load_distance;
        while (cz <= player_chunk[2] + self.chunk_load_distance) : (cz += 1) {
            var cx = player_chunk[0] - self.chunk_load_distance;
            while (cx <= player_chunk[0] + self.chunk_load_distance) : (cx += 1) {
                const dx = cx - player_chunk[0];
                const dz = cz - player_chunk[2];

                if (dx * dx + dz * dz >
                    self.chunk_load_distance * self.chunk_load_distance) continue;

                const slice_coord = ChunkSliceCoord{ cx, cz };

                var cy = self.chunk_min_y;
                while (cy < self.chunk_max_y) : (cy += 1) {
                    const coord = ChunkCoord{ cx, cy, cz };
                    const slot = try world.getOrPutChunkSlot(allocator, coord);

                    switch (slot.state) {
                        .absent => {
                            try self.submitSliceGenerationJob(
                                allocator,
                                world,
                                chunk_worker,
                                slice_coord,
                            );

                            generating_counter += @intCast(self.chunk_max_y - self.chunk_min_y);
                        },

                        .generated => {
                            if (mesher.makeMeshJob(world, coord)) |job| {
                                errdefer job.deinit(allocator);
                                try chunk_worker.submitMeshJob(job);
                                slot.state = .meshing;
                            }
                        },

                        .ready => {
                            if (slot.mesh_dirty) {
                                if (mesher.makeMeshJob(world, coord)) |job| {
                                    errdefer job.deinit(allocator);
                                    try chunk_worker.submitMeshJob(job);
                                    slot.state = .meshing;
                                    slot.mesh_dirty = false;
                                }
                            }
                        },

                        .generating => generating_counter += 1,
                        .meshing => meshing_counter += 1,
                    }

                    self.loaded.appendAssumeCapacity(slot);

                    if (dx * dx + dz * dz <=
                        self.chunk_render_distance * self.chunk_render_distance)
                    {
                        self.active.appendAssumeCapacity(.{
                            .slot = slot,
                            .dist2 = dist2ToPlayer(player_pos, slot),
                        });
                    }
                }
            }
        }

        main.debug_overlay.chunk_generating = generating_counter;
        main.debug_overlay.chunk_meshing = meshing_counter;
        main.debug_overlay.chunk_loaded = self.loaded.items.len;
        main.debug_overlay.chunk_active = self.active.items.len;

        std.sort.block(ChunkRenderEntry, self.active.items, {}, struct {
            fn lessThan(_: void, a: ChunkRenderEntry, b: ChunkRenderEntry) bool {
                return a.dist2 < b.dist2;
            }
        }.lessThan);
    }

    pub fn getVisibleActiveChunks(self: *ChunkManager, combined_mat: Mat4f) []*ChunkSlot {
        const planes = [5]F4{
            combined_mat.r[3] + combined_mat.r[0], // left
            combined_mat.r[3] - combined_mat.r[0], // right
            combined_mat.r[3] + combined_mat.r[1], // bottom
            combined_mat.r[3] - combined_mat.r[1], // top
            combined_mat.r[2], // near
        };

        self.visible.clearRetainingCapacity();

        for (self.active.items) |entry| {
            const world_max: F3 = @floatFromInt(entry.slot.world_max);
            const world_min: F3 = @floatFromInt(entry.slot.world_min);

            var inside = true;

            for (planes) |plane| {
                const point = F4{
                    if (plane[0] >= 0) world_max[0] else world_min[0],
                    if (plane[1] >= 0) world_max[1] else world_min[1],
                    if (plane[2] >= 0) world_max[2] else world_min[2],
                    1,
                };

                const dist = @reduce(.Add, point * plane);
                if (dist < 0) {
                    inside = false;
                    break;
                }
            }

            if (inside and entry.slot.state == .ready)
                if (inside) self.visible.appendAssumeCapacity(entry.slot);
        }

        main.debug_overlay.chunk_visible = self.visible.items.len;

        return self.visible.items;
    }

    pub fn drainWorkerResults(
        _: *ChunkManager,
        allocator: std.mem.Allocator,
        world: *World,
        chunk_worker: *ChunkWorker,
    ) !void {
        while (chunk_worker.pollGenerationResult()) |res|
            try world.publishGenerationResult(allocator, world, res);

        while (chunk_worker.pollMeshResult()) |res|
            try world.publishMeshResult(allocator, res);
    }
};
