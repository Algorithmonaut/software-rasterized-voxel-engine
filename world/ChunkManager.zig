const std = @import("std");

const World = @import("World.zig").World;

const BitfieldViews = @import("Chunk.zig").BitfieldViews;
const ChunkVersion = @import("Chunk.zig").ChunkVersion;
const ChunkSlot = @import("Chunk.zig").ChunkSlot;
const ChunkWorker = @import("ChunkWorker.zig").ChunkWorker;
const Bitfield = @import("Chunk.zig").Bitfield;
const Bitfields = @import("Chunk.zig").Bitfields;
const BlockId = @import("Block.zig").BlockId;

const CHUNK_SIZE = @import("Chunk.zig").CHUNK_SIZE;
const VOXEL_COUNT = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;

const Renderer = @import("../Renderer.zig").Renderer;

const types = @import("../math/types.zig");
const ChunkCoord = types.ChunkCoord;
const F4 = types.Vec4f;
const F3 = types.Vec3f;
const WorldCoord = types.WorldCoord;

const BATCH_SIZE: usize = 16;

const DEBUG_SINGLE_THREADED = @import("../main.zig").DEBUG_SINGLE_THREADED;

const AtomicUsize = std.atomic.Value(usize);

const TerrainGenerator = @import("TerrainGenerator.zig").TerrainGenerator;
const GenerationJob = @import("TerrainGenerator.zig").GenerationJob;
const GenerationResult = @import("TerrainGenerator.zig").GenerationResult;

const mesher = @import("../mesh/mesher.zig");
const MeshJob = mesher.MeshJob;
const MeshResult = mesher.MeshResult;

const Block = @import("Block.zig");
const Vertex = Block.Vertex;
const WorldVertex = Block.WorldVertex;

const Mat4f = @import("../math/matrix.zig").Mat4f;

pub const AtomicU32 = std.atomic.Value(u32);

fn publishGeneratedVersion(
    allocator: std.mem.Allocator,
    slot: *ChunkSlot,
    voxels: []const BlockId,
    bitfields: *const BitfieldViews,
) !usize {
    const next_gen = slot.gen.load(.acquire) + 1;

    const ver = try allocator.create(ChunkVersion);
    ver.* = .{
        .refs = AtomicU32.init(1),
        .gen = next_gen,
        .voxels = voxels,
        .bitfields = bitfields,
    };

    const old = slot.current;
    slot.current = ver;
    slot.gen.store(next_gen, .release);

    // Terrain changed, current mesh is now stale.
    if (slot.mesh) |m| {
        m.deinit(allocator);
        allocator.destroy(m);
        slot.mesh = null;
    }

    if (old) |prev| {
        prev.releaseVersion(allocator);
    }

    return next_gen;
}

//// CHUNK PREGENERATION ///////////////////////////////////////////////////////

fn generationWorker(
    next: *AtomicUsize,
    total: usize,
    allocator: std.mem.Allocator,
    chunk_coords: []ChunkCoord,
    world: *World,
    terrain_generator: *TerrainGenerator,
) void {
    while (true) {
        const base = next.fetchAdd(BATCH_SIZE, .monotonic);
        if (base >= chunk_coords.len) break;
        std.debug.print("GENERATING, REMAINING: {}\n", .{total - base});

        for (0..BATCH_SIZE) |incr| {
            const chunk_coord_i = base + incr;
            if (chunk_coord_i >= chunk_coords.len) break;
            const coord = chunk_coords[chunk_coord_i];

            const result = terrain_generator.fillChunkVoxels(
                allocator,
                .{ .coord = coord },
            ) catch |err| {
                std.debug.panic("fillChunkVoxels failed: {s}", .{@errorName(err)});
            };

            const slot = world.getChunkSlot(coord) orelse return;
            _ = try publishGeneratedVersion(allocator, slot, result.voxels, result.bitfield_views);
            slot.state = .generated;
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
        std.debug.print("MESHING, REMAINING: {}\n", .{total - base});

        for (0..BATCH_SIZE) |incr| {
            const chunk_coord_i = base + incr;
            if (chunk_coord_i >= chunk_coords.len) break;
            const coord = chunk_coords[chunk_coord_i];
            const chunk = world.getChunk(coord) orelse unreachable;

            const result = mesher.generateMesh(
                allocator,
                mesher.makeMeshJob(world, coord),
            ) catch |err| {
                std.debug.panic("generateMesh failed: {s}", .{@errorName(err)});
            };

            chunk.mesh = result.mesh;
            chunk.state = .ready;
        }
    }
}

//// MAIN //////////////////////////////////////////////////////////////////////

pub const ChunkManager = struct {
    pub const ChunkRenderEntry = struct { chunk: *ChunkSlot, dist2: f32 };

    // TODO: Maybe I should keep only chunk_* values here
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

    pub fn init(
        allocator: std.mem.Allocator,
        render_distance: f32,
        load_distance: f32,
        min_world_y: f32,
        max_world_y: f32,
    ) !ChunkManager {
        const loaded_count = chunkCountInSphericalSegment(
            load_distance,
            min_world_y,
            max_world_y,
        );

        const active_count = chunkCountInSphericalSegment(
            render_distance,
            min_world_y,
            max_world_y,
        );

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

            .loaded = try std.ArrayList(*Chunk).initCapacity(allocator, loaded_count),
            .loaded_count = loaded_count,

            .active = try std.ArrayList(ChunkRenderEntry).initCapacity(allocator, active_count),
            .active_count = active_count,

            .visible = try std.ArrayList(*Chunk).initCapacity(allocator, active_count),
        };
    }

    //// CHUNK PREGENERAITON ////

    // NOTE: Due to a (really weird) thread pool bug in zig std,
    // I'am forced to use thread.spawn
    pub fn bootstrapInitialChunks(
        self: *ChunkManager,
        allocator: std.mem.Allocator,
        world: *World,
        terrain_generator: *TerrainGenerator,
    ) !void {
        const count = self.loaded_count;
        var chunk_coords = try std.ArrayList(ChunkCoord).initCapacity(allocator, count);
        defer chunk_coords.deinit(allocator);

        var cz = -self.chunk_load_distance;
        while (cz <= self.chunk_load_distance) : (cz += 1) {
            var cy = self.chunk_min_y;
            while (cy <= self.chunk_max_y) : (cy += 1) {
                var cx = -self.chunk_load_distance;
                while (cx <= self.chunk_load_distance) : (cx += 1) {
                    if (cx * cx + cy * cy + cz * cz >
                        self.chunk_load_distance * self.chunk_load_distance) continue;

                    const coord = ChunkCoord{ cx, cy, cz };
                    _ = try world.insertChunk(allocator, coord);
                    chunk_coords.appendAssumeCapacity(coord);
                }
            }
        }

        var next = AtomicUsize.init(0);

        if (DEBUG_SINGLE_THREADED) {
            generationWorker(
                &next,
                count,
                allocator,
                chunk_coords.items,
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
                count,
                allocator,
                chunk_coords.items,
                world,
                terrain_generator,
            });
            spawned += 1;
        }

        for (threads[0..spawned]) |t| {
            t.join();
        }

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

        for (threads[0..spawned]) |t| {
            t.join();
        }
    }

    //// CHUNK SELECTION ////

    pub fn worldToChunkCoord(coord: WorldCoord) ChunkCoord {
        return .{
            @divFloor(@as(i32, @intFromFloat(@floor(coord[0]))), CHUNK_SIZE),
            @divFloor(@as(i32, @intFromFloat(@floor(coord[1]))), CHUNK_SIZE),
            @divFloor(@as(i32, @intFromFloat(@floor(coord[2]))), CHUNK_SIZE),
        };
    }

    /// Returns the avg of the two AABB points aka. chunk center
    pub fn chunkCenter(chunk: *const Chunk) @Vector(3, f32) {
        const half_vec = @as(@Vector(3, f32), @splat(0.5));
        const world_min: @Vector(3, f32) = @floatFromInt(chunk.world_min);
        const world_max: @Vector(3, f32) = @floatFromInt(chunk.world_max);

        return (world_min + world_max) * half_vec;
    }

    fn dist2ToPlayer(player: WorldCoord, chunk: *const Chunk) f32 {
        const c = chunkCenter(chunk);
        const d = c - player;
        return d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
    }

    pub fn worldVertexFromChunkVertex(
        vert: Vertex,
        chunk_pos: ChunkCoord,
        chunk_size: usize,
    ) WorldVertex {
        const v_pos_f: F3 = @floatFromInt(vert.pos);
        const chunk_pos_f: F3 = @floatFromInt(chunk_pos);
        const size_splat_f: F3 = @splat(@as(f32, @floatFromInt(chunk_size)));

        const temp: F3 = v_pos_f + chunk_pos_f * size_splat_f;
        const v_pos: F4 = .{ temp[0], temp[1], temp[2], 1 };

        return .{
            .pos = v_pos,
            .uv = vert.uv,
        };
    }

    /// Will run only when player's active chunk position changes
    pub fn updateChunks(
        self: *ChunkManager,
        allocator: std.mem.Allocator,
        world: *World,
        chunk_worker: *ChunkWorker,
        player_pos: F3,
    ) !void {
        const player_chunk = worldToChunkCoord(player_pos);

        // No need to check for y
        if (player_chunk[0] == self.last_player_chunk[0] and
            player_chunk[2] == self.last_player_chunk[2])
            return;

        self.last_player_chunk = player_chunk;

        // for (self.loaded.items) |chunk| {
        //     if (chunk.edited) continue;
        //
        //     const dx = chunk.coord[0] - player_chunk[0];
        //     const dz = chunk.coord[2] - player_chunk[2];
        //
        //     if (dx * dx + dz * dz > self.chunk_load_distance * self.chunk_load_distance)
        //         world.removeChunk(chunk.coord);
        // }

        self.loaded.clearRetainingCapacity();
        self.active.clearRetainingCapacity();

        _ = chunk_worker;

        var cz = player_chunk[2] - self.chunk_load_distance;
        while (cz <= player_chunk[2] + self.chunk_load_distance) : (cz += 1) {
            var cy = self.chunk_min_y;
            while (cy <= self.chunk_max_y) : (cy += 1) {
                var cx = player_chunk[0] - self.chunk_load_distance;
                while (cx <= player_chunk[0] + self.chunk_load_distance) : (cx += 1) {
                    const dx = cx - player_chunk[0];
                    const dy = cy;
                    const dz = cz - player_chunk[2];

                    //// MANAGE LOADED CHUNKS ////

                    if (dx * dx + dy * dy + dz * dz >
                        self.chunk_load_distance * self.chunk_load_distance) continue;

                    const coord = ChunkCoord{ cx, cy, cz };
                    const chunk = try world.insertChunk(allocator, coord);

                    // switch (chunk.state) {
                    //     .absent => {
                    //         try chunk_worker.submitGenerationJob(.{ .coord = coord });
                    //         chunk.state = .generating;
                    //     },
                    //     .generated => {
                    //         try chunk_worker.submitMeshJob(createMeshJob(chunk, world));
                    //         chunk.state = .meshing;
                    //     },
                    //     else => {},
                    // }
                    //
                    // self.loaded.appendAssumeCapacity(chunk);

                    //// MANAGE ACTIVE CHUNKS ////

                    if (dx * dx + dy * dy + dz * dz <=
                        self.chunk_render_distance * self.chunk_render_distance)
                        self.active.appendAssumeCapacity(.{
                            .chunk = chunk,
                            .dist2 = dist2ToPlayer(player_pos, chunk),
                        });
                }
            }
        }

        //// SORT LOADED CHUNKS ////

        // Front to back rendering
        std.sort.block(ChunkRenderEntry, self.active.items, {}, struct {
            fn lessThan(_: void, a: ChunkRenderEntry, b: ChunkRenderEntry) bool {
                return a.dist2 < b.dist2;
            }
        }.lessThan);
    }

    pub fn getVisibleActiveChunks(self: *ChunkManager, combined_mat: Mat4f) []*Chunk {
        const planes = [5]F4{
            combined_mat.r[3] + combined_mat.r[0], // left
            combined_mat.r[3] - combined_mat.r[0], // right
            combined_mat.r[3] + combined_mat.r[1], // bottom
            combined_mat.r[3] - combined_mat.r[1], // top
            combined_mat.r[2], // near
        };

        self.visible.clearRetainingCapacity();

        for (self.active.items) |entry| {
            const world_max: F3 = @floatFromInt(entry.chunk.world_max);
            const world_min: F3 = @floatFromInt(entry.chunk.world_min);

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

            if (inside and entry.chunk.state == .ready)
                if (inside) self.visible.appendAssumeCapacity(entry.chunk);
        }

        return self.visible.items;
    }

    pub fn drainWorkerResults(
        _: *ChunkManager,
        allocator: std.mem.Allocator,
        world: *World,
        chunk_worker: *ChunkWorker,
    ) void {
        while (chunk_worker.pollGenerationResult()) |job| {
            if (world.getChunk(job.coord)) |chunk| {
                allocator.free(chunk.voxels);
                allocator.destroy(chunk.bitfields);
                chunk.voxels = job.voxels;
                chunk.bitfields = job.bitfield_views;
                chunk.state = .generated;
            }
        }

        while (chunk_worker.pollMeshJob()) |job| {
            if (world.getChunk(job.coord)) |chunk| {
                chunk.mesh.deinit(allocator);
                allocator.destroy(chunk.mesh);
                chunk.mesh = job.mesh;
                chunk.state = .ready;
            }
        }
    }
};
