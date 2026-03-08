const std = @import("std");
const Chunk = @import("Chunck.zig").Chunk;

const ChunkCoord = @import("math/types.zig").ChunkCoord;

pub const World = struct {
    allocator: std.mem.Allocator,
    chuncks: std.AutoHashMap(u64, *Chunk),

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .chuncks = std.AutoHashMap(u64, *Chunk),
        };
    }

    pub fn deinit(self: *World) void {
        var it = self.chuncks.valueIterator();
        while (it.next()) |chunk_ptr| {
            chunk_ptr.deinit(self.allocator);
        }

        self.chuncks.deinit();
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

        return (x << 42) | (y << 42) | z;
    }

    pub fn getChunk(self: *World, coord: ChunkCoord) ?*Chunk {
        return self.chuncks.get(chunkKey(coord));
    }

    pub fn ensureChunk(self: *World, coord: ChunkCoord) !*Chunk {
        const key = chunkKey(coord);

        if (self.chuncks.get(key)) |chunk| {
            return chunk;
        }

        const chunk_ptr = try self.allocator.create(Chunk);
        errdefer self.allocator.destroy(chunk_ptr);

        chunk_ptr.* = try Chunk.generate(self.allocator, coord);
        errdefer chunk_ptr.deinit(self.allocator);
    }

    pub fn removeChunk(self: *World, coord: ChunkCoord) bool {
        const key = chunkKey(coord);

        if (self.chuncks.fetchRemove(key)) |entry| {
            entry.value.deinit(self.allocator);
            self.allocator.destroy(entry.value);
            return true;
        }

        return false;
    }
};
