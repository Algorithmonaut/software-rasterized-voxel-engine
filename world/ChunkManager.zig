const std = @import("std");
const types = @import("../math/types.zig");
const mesher = @import("../mesh/mesher.zig");

const ChunkCoord = types.ChunkCoord;
const WorldCoord = types.WorldCoord;
const F4 = types.Vec4f;
const F3 = types.Vec3f;
const ChunkSlot = @import("Chunk.zig").ChunkSlot;
const ChunkVersion = @import("Chunk.zig").ChunkVersion;
const ChunkWorker = @import("ChunkWorker.zig").ChunkWorker;
const World = @import("World.zig").World;
const GenerationResult = @import("TerrainGenerator.zig").GenerationResult;
const MeshResult = @import("../mesh/mesher.zig").MeshResult;
const Mat4f = @import("../math/matrix.zig").Mat4f;

const CHUNK_SIZE = @import("Chunk.zig").CHUNK_SIZE;
const VOXEL_COUNT = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;

pub const AtomicU32 = std.atomic.Value(u32);

//// HELPERS ////

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

//// MAIN ////

fn publishGenerationResult(
    allocator: std.mem.Allocator,
    world: *World,
    res: GenerationResult,
) !void {
    errdefer {
        allocator.free(res.voxels);
        allocator.destroy(res.bitfield_views);
    }

    const slot = world.getChunkSlot(res.coord) orelse {
        allocator.free(res.voxels);
        allocator.destroy(res.bitfield_views);
        return;
    };

    const next_gen = slot.gen.load(.acquire) + 1;

    const ver = try allocator.create(ChunkVersion);
    ver.* = .{
        .refs = AtomicU32.init(1),
        .gen = next_gen,
        .voxels = res.voxels,
        .bitfields = res.bitfield_views,
    };

    const prev = slot.current;
    slot.current = ver;
    slot.gen.store(next_gen, .release);
    if (prev) |old| old.releaseVersion(allocator);

    if (slot.mesh) |m| {
        m.deinit(allocator);
        allocator.destroy(m);
        slot.mesh = null;
    }
}

fn publishMeshResult(
    allocator: std.mem.Allocator,
    world: *World,
    res: MeshResult,
) !void {
    const slot = world.getChunkSlot(res.coord) orelse {
        res.mesh.deinit(allocator);
        allocator.destroy(res.mesh);
        return;
    };

    // Reject stale mesh result
    if (res.source_gen != slot.gen.load(.acquire) or slot.current == null) {
        res.mesh.deinit(allocator);
        allocator.destroy(res.mesh);
        return;
    }

    if (slot.mesh) |old_mesh| {
        old_mesh.deinit(allocator);
        allocator.destroy(old_mesh);
    }

    slot.mesh = res.mesh;
    slot.state = .ready;
}

pub const ChunkManager = struct {
    pub const ChunkRenderEntry = struct { slot: *ChunkSlot, dist2: f32 };

    chunk_render_distance: i32,
    chunk_load_distance: i32,

    chunk_min_y: i32,
    chunk_max_y: i32,

    loaded: std.ArrayList(*ChunkSlot),
    loaded_count: usize,

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

            .active = try std.ArrayList(ChunkRenderEntry).initCapacity(allocator, active_count),
            .active_count = active_count,

            .visible = try std.ArrayList(*ChunkSlot).initCapacity(allocator, active_count),
        };
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

        var cz = player_chunk[2] - self.chunk_load_distance;
        while (cz <= player_chunk[2] + self.chunk_load_distance) : (cz += 1) {
            var cy = self.chunk_min_y;
            while (cy <= self.chunk_max_y) : (cy += 1) {
                var cx = player_chunk[0] - self.chunk_load_distance;
                while (cx <= player_chunk[0] + self.chunk_load_distance) : (cx += 1) {
                    const dx = cx - player_chunk[0];
                    const dy = cy;
                    const dz = cz - player_chunk[2];

                    if ((dx * dx) + (dy * dy) + (dz * dz) >
                        self.chunk_load_distance * self.chunk_load_distance) continue;

                    const coord = ChunkCoord{ cx, cy, cz };
                    const slot = try world.getOrPutChunkSlot(allocator, coord);

                    switch (slot.state) {
                        .absent => {
                            // Maybe submit coord directly rather than a struct
                            try chunk_worker.submitGenerationJob(.{ .coord = coord });
                            slot.state = .generating;
                        },
                        .generated => {
                            if (mesher.makeMeshJob(world, coord)) |job| {
                                errdefer job.deinit(allocator);
                                try chunk_worker.submitMeshJob(job);
                                slot.state = .meshing;
                            }
                        },
                        else => {},
                    }

                    self.loaded.appendAssumeCapacity(slot);

                    if ((dx * dx) + (dy * dy) + (dz * dz) <=
                        self.chunk_render_distance * self.chunk_render_distance)
                        self.active.appendAssumeCapacity(.{
                            .slot = slot,
                            .dist2 = dist2ToPlayer(player_pos, slot),
                        });
                }
            }

            var absent: usize = 0;
            var generating: usize = 0;
            var generated: usize = 0;
            var meshing: usize = 0;
            var ready: usize = 0;

            var it = world.chunks.valueIterator();
            while (it.next()) |slot_ptr| {
                const slot = slot_ptr.*;
                switch (slot.state) {
                    .absent => absent += 1,
                    .generating => generating += 1,
                    .generated => generated += 1,
                    .meshing => meshing += 1,
                    .ready => ready += 1,
                }
            }

            std.debug.print(
                "states: absent={} generating={} generated={} meshing={} ready={}\n",
                .{ absent, generating, generated, meshing, ready },
            );
        }

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

        return self.visible.items;
    }

    pub fn drainWorkerResults(
        _: *ChunkManager,
        allocator: std.mem.Allocator,
        world: *World,
        chunk_worker: *ChunkWorker,
    ) !void {
        while (chunk_worker.pollGenerationResult()) |res|
            try publishGenerationResult(allocator, world, res);

        while (chunk_worker.pollMeshResult()) |res|
            try publishMeshResult(allocator, world, res);
    }
};
