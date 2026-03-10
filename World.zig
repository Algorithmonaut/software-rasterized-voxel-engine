const std = @import("std");
const Chunk = @import("Chunk.zig").Chunk;
const WorldConfig = @import("EngineConfig.zig").EngineConfig.WorldConfig;

const ChunkCoord = @import("math/types.zig").ChunkCoord;

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

    // We want a ordinary hashable scalar,
    // apparently can have weird representation / comparaison constraints
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

    pub fn ensureChunk(self: *World, coord: ChunkCoord) !*Chunk {
        const key = chunkKey(coord);

        if (self.chunks.get(key)) |chunk| {
            return chunk;
        }

        const chunk_ptr = try self.allocator.create(Chunk);
        errdefer self.allocator.destroy(chunk_ptr);

        chunk_ptr.* = try Chunk.generate(self.allocator, coord, self.chunk_size);
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
};
