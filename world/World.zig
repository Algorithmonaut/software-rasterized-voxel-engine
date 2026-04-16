const std = @import("std");
const helpers = @import("../helpers.zig");
const types = @import("../math/types.zig");

const ChunkSlot = @import("Chunk.zig").ChunkSlot;
const CHUNK_SIZE = @import("Chunk.zig").CHUNK_SIZE;

const ChunkCoord = types.ChunkCoord;
const I3 = types.Vec3i;

const BlockId = @import("Block.zig").BlockId;

const TerrainGenerator = @import("TerrainGenerator.zig").TerrainGenerator;

pub const World = struct {
    // When AutoHashMap grows or rehashes, its values can move, so we need ptr
    chunks: std.AutoHashMap(u64, *ChunkSlot),

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .chunks = std.AutoHashMap(u64, *ChunkSlot).init(allocator),
        };
    }

    pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
        var it = self.chunks.valueIterator();
        while (it.next()) |slot_ptr| {
            slot_ptr.*.destroy(allocator);
            allocator.destroy(slot_ptr);
        }

        self.chunks.deinit();
    }

    pub inline fn chunkKey(coord: ChunkCoord) u64 {
        // [-1048576, +1048575] (i32) ===[1 << 20 = 1048576]===> [0, 2097151]
        // [0, 2097151] fits in 21 bits; 21*3 = 63 bits
        const bias: i64 = 1 << 20;

        const x: u64 = @intCast(@as(i64, coord[0]) + bias);
        const y: u64 = @intCast(@as(i64, coord[1]) + bias);
        const z: u64 = @intCast(@as(i64, coord[2]) + bias);

        return (x << 42) | (y << 21) | z;
    }

    pub inline fn getChunkSlot(self: *World, coord: ChunkCoord) ?*ChunkSlot {
        return self.chunks.get(chunkKey(coord));
    }

    pub inline fn getOrPutChunkSlot(
        self: *World,
        allocator: std.mem.Allocator,
        coord: ChunkCoord,
    ) !*ChunkSlot {
        const key = chunkKey(coord);
        const gop = try self.chunks.getOrPut(chunkKey(coord));
        if (!gop.found_existing) {
            errdefer _ = self.chunks.remove(key);

            const slot = try allocator.create(ChunkSlot);
            slot.* = ChunkSlot.create(coord);
            gop.value_ptr.* = slot;
        }
        return gop.value_ptr;
    }

    pub inline fn removeChunkSlot(
        self: *World,
        allocator: std.mem.Allocator,
        coord: ChunkCoord,
    ) void {
        if (self.chunks.fetchRemove(chunkKey(coord))) |entry| {
            entry.value.destroy(allocator);
            allocator.destroy(entry.value);
        }
    }

    pub inline fn getBlockIdFromWorldCoordinates(self: *World, coord: I3) BlockId {
        const chunk_size_vec: I3 = @splat(CHUNK_SIZE);

        const chunk_pos: I3 = @divFloor(coord, chunk_size_vec);
        const local_pos: @Vector(3, usize) = @intCast(@mod(coord, chunk_size_vec));

        if (self.getChunkSlot(chunk_pos)) |chunk_slot| {
            if (chunk_slot.current) |cur| return cur.voxels[
                helpers.voxelIndex(CHUNK_SIZE, local_pos[0], local_pos[1], local_pos[2])
            ];
        }
        return .unknown;
    }
};
