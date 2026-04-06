const std = @import("std");
const Chunk = @import("Chunk.zig").Chunk;
const WorldConfig = @import("EngineConfig.zig").EngineConfig.WorldConfig;

const ChunkCoord = @import("math/types.zig").ChunkCoord;

const Mesher = @import("world/Mesher.zig").Mesher;
const MesherFile = @import("world/Mesher.zig");
const TerrainGenerator = @import("world/TerrainGenerator.zig").TerrainGenerator;

const types = @import("math/types.zig");
const WorldCoord = types.WorldCoord;
const Vec3i = types.Vec3i;
const BlockId = @import("world/Block.zig").BlockId;

const Renderer = @import("Renderer.zig").Renderer;

pub const World = struct {
    allocator: std.mem.Allocator,
    chunks: std.AutoHashMap(u64, *Chunk),
    chunk_size: usize,

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .chunks = std.AutoHashMap(u64, *Chunk).init(allocator),
            // Remove magic number
            .chunk_size = 32,
        };
    }

    pub fn deinit(self: *World) void {
        var it = self.chunks.valueIterator();
        while (it.next()) |chunk_ptr| {
            chunk_ptr.deinit(self.allocator);
        }

        self.chunks.deinit();
    }

    inline fn chunkKey(coord: ChunkCoord) u64 {
        // [-1048576, +1048575] (i32) ===[1 << 20 = 1048576]===> [0, 2097151]
        // [0, 2097151] fits in 21 bits; 21*3 = 63 bits
        const bias: i64 = 1 << 20;

        const x: u64 = @intCast(@as(i64, coord[0]) + bias);
        const y: u64 = @intCast(@as(i64, coord[1]) + bias);
        const z: u64 = @intCast(@as(i64, coord[2]) + bias);

        return (x << 42) | (y << 21) | z;
    }

    pub fn getChunk(self: *World, coord: ChunkCoord) ?*Chunk {
        return self.chunks.get(chunkKey(coord));
    }

    pub fn getBlockIdFromWorldCoordinates(
        self: *World,
        coord: Vec3i,
        chunk_size: i32,
    ) BlockId {
        const chunk_size_vec: Vec3i = @splat(chunk_size);
        const chunk_size_u: usize = @intCast(chunk_size);

        const chunk_pos: Vec3i = @divFloor(coord, chunk_size_vec);
        const local_pos: @Vector(3, usize) = @intCast(@mod(coord, chunk_size_vec));

        if (self.getChunk(chunk_pos)) |chunk| return chunk.lods.lod0[
            local_pos[0] + local_pos[1] * chunk_size_u +
                local_pos[2] * chunk_size_u * chunk_size_u
        ];

        return BlockId.unknown;
    }

    pub fn ensureChunk(
        self: *World,
        coord: ChunkCoord,
        terrain_generator: *TerrainGenerator,
    ) !*Chunk {
        const key = chunkKey(coord);

        if (self.chunks.get(key)) |chunk| {
            return chunk;
        }

        const chunk_ptr = try self.allocator.create(Chunk);
        errdefer self.allocator.destroy(chunk_ptr);

        chunk_ptr.* = try Chunk.generate(
            self.allocator,
            coord,
            self.chunk_size,
            self,
            terrain_generator,
        );

        try self.chunks.put(key, chunk_ptr);
        return chunk_ptr;
    }

    pub fn removeChunk(self: *World, coord: ChunkCoord) bool {
        const key = chunkKey(coord);

        if (self.chunks.fetchRemove(key)) |entry| {
            entry.value.deinit(self.allocator);
            self.allocator.destroy(entry.value);
            return true;
        }

        return false;
    }

    pub fn meshChunks(
        self: *World,
        allocator: std.mem.Allocator,
        mesher: *Mesher,
    ) !void {
        _ = allocator;
        var it = self.chunks.iterator();

        while (it.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (!chunk.dirty or chunk.queued or chunk.meshing) continue;

            chunk.queued = true;

            try mesher.enqueue(.{
                .world = self,
                .chunk = chunk,
            });
        }
    }

    pub fn bootstrapInitialChunks(
        self: *World,
        allocator: std.mem.Allocator,
        player_pos: WorldCoord,
        view_distance: f32,
        terrain_generator: *TerrainGenerator,
        world: *World,
    ) !void {
        _ = player_pos;
        // const chunk_size_i: i32 = @intCast(self.chunk_size);

        var prepared: usize = 0;

        const horizontal_radius: i32 = @intFromFloat(@ceil(
            view_distance / @as(f32, @floatFromInt(self.chunk_size)),
        ));

        const VERTICAL_MIN: i32 = -2;
        const VERTICAL_MAX: i32 = 0;

        var cz = -horizontal_radius;
        while (cz <= horizontal_radius) : (cz += 1) {
            var cy = VERTICAL_MIN;
            while (cy <= VERTICAL_MAX) : (cy += 1) {
                var cx = -horizontal_radius;
                while (cx <= horizontal_radius) : (cx += 1) {
                    const dx: i64 = @intCast(cx);
                    const dz: i64 = @intCast(cz);

                    if (dx * dx + dz * dz > horizontal_radius * horizontal_radius) continue;

                    prepared += 1;
                    if (prepared % 10 == 0) std.debug.print("PREPARED: {}\n", .{prepared});

                    _ = try self.ensureChunk(.{ cx, cy, cz }, terrain_generator);
                }
            }
        }

        var it = self.chunks.iterator();
        var counter: usize = 0;

        while (it.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (!chunk.dirty) continue;
            try MesherFile.generateMesh(chunk, world, allocator);
            if (self.chunks.get(entry.key_ptr.*)) |c| c.dirty = false;
            counter += 1;
            if (counter % 10 == 0) std.debug.print("REMAINING TO BE MESHED: {}\n", .{prepared - counter});
        }
    }
};
