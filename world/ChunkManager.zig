const std = @import("std");

const World = @import("World.zig").World;

const Chunk = @import("Chunk.zig").Chunk;
const Bitfield = @import("Chunk.zig").Bitfield;
const Bitfields = @import("Chunk.zig").Bitfields;
const createBitfields = @import("Chunk.zig").createBitfields;
const CHUNK_SIZE = @import("Chunk.zig").CHUNK_SIZE;

const types = @import("../math/types.zig");
const ChunkCoord = types.ChunkCoord;

const BATCH_SIZE: usize = 16;

const AtomicUsize = std.atomic.Value(usize);

const TerrainGenerator = @import("TerrainGenerator.zig").TerrainGenerator;
const GenerationJob = @import("TerrainGenerator.zig").GenerationJob;
const GenerationResult = @import("TerrainGenerator.zig").GenerationResult;

const mesher = @import("../mesh/mesher.zig");
const MeshJob = mesher.MeshJob;
const MeshResult = mesher.MeshResult;

const Axis = enum(u8) { x, y, z };

fn neighborBitfields(comptime axis: Axis, neighbor: ?*Chunk) ?*const Bitfields {
    const adj = neighbor orelse return null;
    if (adj.state == .absent or adj.state == .generating) return null;

    return switch (axis) {
        .x => &adj.bitfields.solid_x,
        .y => &adj.bitfields.solid_y,
        .z => &adj.bitfields.solid_z,
    };
}

fn createMeshJob(chunk: *Chunk, world: *World) MeshJob {
    const c = chunk.coord;

    const pos_x = neighborBitfields(.x, world.getChunk(.{ c[0] + 1, c[1], c[2] }));
    const neg_x = neighborBitfields(.x, world.getChunk(.{ c[0] - 1, c[1], c[2] }));

    const pos_y = neighborBitfields(.y, world.getChunk(.{ c[0], c[1] + 1, c[2] }));
    const neg_y = neighborBitfields(.y, world.getChunk(.{ c[0], c[1] - 1, c[2] }));

    const pos_z = neighborBitfields(.z, world.getChunk(.{ c[0], c[1], c[2] + 1 }));
    const neg_z = neighborBitfields(.z, world.getChunk(.{ c[0], c[1], c[2] - 1 }));

    return .{
        .coord = c,
        .voxels = chunk.voxels,
        .chunk_bitfield_views = &chunk.bitfields,
        .pos_x_neighbor_bitfields_solid_x = pos_x,
        .neg_x_neighbor_bitfields_solid_x = neg_x,
        .pos_y_neighbor_bitfields_solid_y = pos_y,
        .neg_y_neighbor_bitfields_solid_y = neg_y,
        .pos_z_neighbor_bitfields_solid_z = pos_z,
        .neg_z_neighbor_bitfields_solid_z = neg_z,
    };
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
            const chunk = world.getChunk(coord) orelse unreachable;

            const result = terrain_generator.fillChunkVoxels(
                allocator,
                .{ .coord = coord },
            ) catch |err| {
                std.debug.panic("fillChunkVoxels failed: {s}", .{@errorName(err)});
            };

            // TODO: FREE THE VOXELS BEFORE IF NO SOLUTION IS FOUND
            chunk.voxels = result.voxels;
            chunk.bitfields = createBitfields(result.voxels);
            chunk.state = .generated;
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
                createMeshJob(chunk, world),
            ) catch |err| {
                std.debug.panic("generateMesh failed: {s}", .{@errorName(err)});
            };

            chunk.mesh = result.mesh;
            chunk.state = .ready;
        }
    }
}

pub const ChunkManager = struct {
    render_distance: f32 = 800,
    load_distance: f32 = 1000,

    min_world_y: i32,
    max_world_y: i32,

    pub fn init(
        render_distance: f32,
        load_distance: f32,
        min_world_y: i32,
        max_world_y: i32,
    ) ChunkManager {
        return .{
            .render_distance = render_distance,
            .load_distance = load_distance,
            .min_world_y = min_world_y,
            .max_world_y = max_world_y,
        };
    }

    pub fn bootstrapInitialChunks(
        self: *ChunkManager,
        allocator: std.mem.Allocator,
        pool: *std.Thread.Pool,
        world: *World,
        terrain_generator: *TerrainGenerator,
    ) !void {
        var chunk_coords = try std.ArrayList(ChunkCoord).initCapacity(allocator, 1_000_000);

        const chunk_load_distance: i32 = @intFromFloat(@ceil(self.load_distance /
            CHUNK_SIZE));

        const chunk_min_y: i32 = try std.math.divFloor(i32, self.min_world_y, CHUNK_SIZE);
        const chunk_max_y: i32 = try std.math.divCeil(i32, self.max_world_y, CHUNK_SIZE);

        var counter: usize = 0;

        var cz = -chunk_load_distance;
        while (cz <= chunk_load_distance) : (cz += 1) {
            var cy = chunk_min_y;
            while (cy <= chunk_max_y) : (cy += 1) {
                var cx = -chunk_load_distance;
                while (cx <= chunk_load_distance) : (cx += 1) {
                    if (cx * cx + cy * cy + cz * cz >
                        chunk_load_distance * chunk_load_distance) continue;
                    const coord = ChunkCoord{ cx, cy, cz };
                    _ = try world.insertChunk(allocator, coord);
                    try chunk_coords.append(allocator, coord);
                    counter += 1;
                }
            }
        }

        var next = AtomicUsize.init(0);
        var wg = std.Thread.WaitGroup{};
        const worker_count = try std.Thread.getCpuCount();

        for (0..worker_count) |_| {
            pool.spawnWg(&wg, generationWorker, .{
                &next,
                counter,
                allocator,
                chunk_coords.items,
                world,
                terrain_generator,
            });
        }
        wg.wait();

        next.store(0, .monotonic);
        for (0..worker_count) |_| {
            pool.spawnWg(&wg, meshingWorker, .{
                &next,
                counter,
                allocator,
                chunk_coords.items,
                world,
            });
        }
        wg.wait();
    }
};
