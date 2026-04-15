const std = @import("std");

const Chunk = @import("Chunk.zig").Chunk;
const CHUNK_SIZE = @import("Chunk.zig").CHUNK_SIZE;

const types = @import("../math/types.zig");
const ChunkCoord = types.ChunkCoord;
const I3 = types.Vec3i;

const BlockId = @import("Block.zig").BlockId;

const TerrainGenerator = @import("TerrainGenerator.zig").TerrainGenerator;

pub const World = struct {
    allocator: std.mem.Allocator,
    chunks: std.AutoHashMap(u64, *Chunk),

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .chunks = std.AutoHashMap(u64, *Chunk).init(allocator),
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

    pub fn insertChunk(
        self: *World,
        allocator: std.mem.Allocator,
        coord: ChunkCoord,
    ) !*Chunk {
        const key = chunkKey(coord);

        if (self.chunks.get(key)) |chunk| return chunk;

        const chunk_ptr = try self.allocator.create(Chunk);
        errdefer self.allocator.destroy(chunk_ptr);

        chunk_ptr.* = try Chunk.create(allocator, coord);

        try self.chunks.put(key, chunk_ptr);

        return chunk_ptr;
    }

    pub fn removeChunk(self: *World, coord: ChunkCoord) void {
        const key = chunkKey(coord);

        if (self.chunks.fetchRemove(key)) |entry| {
            entry.value.deinit(self.allocator);
            self.allocator.destroy(entry.value);
        }
    }

    pub fn getBlockIdFromWorldCoordinates(self: *World, coord: I3) BlockId {
        const chunk_size_vec: I3 = @splat(CHUNK_SIZE);

        const chunk_pos: I3 = @divFloor(coord, chunk_size_vec);
        const local_pos: @Vector(3, usize) = @intCast(@mod(coord, chunk_size_vec));

        if (self.getChunk(chunk_pos)) |chunk| return chunk.voxels[
            local_pos[0] + local_pos[1] * CHUNK_SIZE +
                local_pos[2] * CHUNK_SIZE * CHUNK_SIZE
        ];

        return .unknown;
    }
};
