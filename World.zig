const std = @import("std");
const Chunk = @import("Chunk.zig").Chunk;
const WorldConfig = @import("EngineConfig.zig").EngineConfig.WorldConfig;

const ChunkCoord = @import("math/types.zig").ChunkCoord;

const chunk_mesher = @import("world/chunk-mesher.zig");
const TerrainGenerator = @import("world/TerrainGenerator.zig").TerrainGenerator;

const t = @import("math/types.zig");
const WorldCoord = t.WorldCoord;

const Renderer = @import("Renderer.zig").Renderer;

pub const World = struct {
    allocator: std.mem.Allocator,
    chunks: std.AutoHashMap(u64, *Chunk),
    chunk_size: usize,

    pub fn init(allocator: std.mem.Allocator, conf: WorldConfig) World {
        return .{
            .allocator = allocator,
            .chunks = std.AutoHashMap(u64, *Chunk).init(allocator),
            .chunk_size = conf.chunk_size,
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

    pub fn ensureChunk(
        self: *World,
        coord: ChunkCoord,
        terrain_generator: TerrainGenerator,
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
        errdefer chunk_ptr.deinit(self.allocator);

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

    pub fn meshChunks(self: *World, allocator: std.mem.Allocator) !void {
        var it = self.chunks.iterator();

        while (it.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (!chunk.dirty) continue;

            try chunk_mesher.generateMesh(chunk, self, allocator);
            chunk.dirty = false;
        }
    }

    pub fn meshChunksBudgeted(
        self: *World,
        allocator: std.mem.Allocator,
        budget: usize,
    ) !void {
        var done: usize = 0;
        var it = self.chunks.iterator();

        while (it.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (!chunk.dirty) continue;

            try chunk_mesher.generateMesh(chunk, self, allocator);
            chunk.dirty = false;

            done += 1;
            if (done >= budget) break;
        }
    }

    pub fn bootstrapInitialChunks(
        self: *World,
        allocator: std.mem.Allocator,
        player_pos: WorldCoord,
        view_distance: f32,
        terrain_generator: TerrainGenerator,
    ) !void {
        const chunk_size_i: i32 = @intCast(self.chunk_size);
        const player_chunk = Renderer.worldToChunkCoord(player_pos, chunk_size_i);

        const chunk_view_radius: i32 = @intFromFloat(@ceil(
            view_distance / @as(f32, @floatFromInt(self.chunk_size)),
        ));

        var cz = player_chunk[2] - chunk_view_radius;
        while (cz <= player_chunk[2] + chunk_view_radius) : (cz += 1) {
            var cy = player_chunk[1] - chunk_view_radius;
            while (cy <= player_chunk[1] + chunk_view_radius) : (cy += 1) {
                var cx = player_chunk[0] - chunk_view_radius;
                while (cx <= player_chunk[0] + chunk_view_radius) : (cx += 1) {
                    const dx: i64 = @intCast(cx - player_chunk[0]);
                    const dy: i64 = @intCast(cy - player_chunk[1]);
                    const dz: i64 = @intCast(cz - player_chunk[2]);

                    if (dx * dx + dy * dy + dz * dz > chunk_view_radius * chunk_view_radius) continue;

                    _ = try self.ensureChunk(.{ cx, cy, cz }, terrain_generator);
                }
            }
        }

        try self.meshChunks(allocator);
    }
};
