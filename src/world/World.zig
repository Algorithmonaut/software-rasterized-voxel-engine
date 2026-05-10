const std = @import("std");
const chunk = @import("chunk.zig");
const types = @import("../types.zig");
const constants = @import("../constants.zig");
const helpers = @import("../helpers.zig");

const I3 = types.I3;
const Block = types.Block;
const BitfieldViews = types.BitfieldViews;
const BlockId = types.BlockId;
const ChunkCoord = types.ChunkCoord;
const ChunkSlot = chunk.ChunkSlot;
const ChunkVersion = chunk.ChunkVersion;
const AtomicU32 = std.atomic.Value(u32);
const MeshResult = @import("../mesh/mesher.zig").MeshResult;
const GenerationResult = @import("TerrainGenerator.zig").GenerationResult;
const TerrainGenerator = @import("TerrainGenerator.zig").TerrainGenerator;

const CHUNK_SIZE = constants.CHUNK_SIZE;

// NOTE: This shouldn't be here
inline fn generateChunkBitfieldViews(voxels: []Block, bitfield_views: *BitfieldViews) void {
    bitfield_views.* = std.mem.zeroes(BitfieldViews);

    const size = CHUNK_SIZE;

    for (0..size) |x_u| {
        const x: u5 = @intCast(x_u);
        const mx: u32 = @as(u32, 1) << x;

        for (0..size) |y_u| {
            const y: u5 = @intCast(y_u);
            const my: u32 = @as(u32, 1) << y;

            for (0..size) |z_u| {
                const z: u5 = @intCast(z_u);
                const mz: u32 = @as(u32, 1) << z;

                const idx = helpers.voxelIndex(size, x_u, y_u, z_u);
                const voxel = voxels[idx];

                if (voxel.id == .air) continue;

                bitfield_views.renderable_x[y_u][z_u] |= mx;
                bitfield_views.renderable_y[x_u][z_u] |= my;
                bitfield_views.renderable_z[x_u][y_u] |= mz;

                if (!(voxel.id == .glass or voxel.id == .oak_leaves)) {
                    bitfield_views.occluder_x[y_u][z_u] |= mx;
                    bitfield_views.occluder_y[x_u][z_u] |= my;
                    bitfield_views.occluder_z[x_u][y_u] |= mz;
                }
            }
        }
    }
}

pub const World = struct {
    // When AutoHashMap grows or rehashes, its values can move, so we need ptr
    chunks: std.AutoHashMap(u64, *ChunkSlot),

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .chunks = std.AutoHashMap(u64, *ChunkSlot).init(allocator),
        };
    }

    pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
        var it = self.chunks.valueIterator();
        while (it.next()) |slot_ptr| {
            slot_ptr.*.destroy(allocator);
            allocator.destroy(slot_ptr.*);
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
        return gop.value_ptr.*;
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
            ].id;
        }
        return .unknown;
    }

    pub inline fn setBlockIdFromWorldCoordinates(self: *World, coord: I3, id: BlockId) void {
        const chunk_size_vec: I3 = @splat(CHUNK_SIZE);

        const chunk_pos: I3 = @divFloor(coord, chunk_size_vec);
        const local_pos: @Vector(3, usize) = @intCast(@mod(coord, chunk_size_vec));

        if (self.getChunkSlot(chunk_pos)) |chunk_slot| {
            if (chunk_slot.current) |cur| {
                cur.voxels[
                    helpers.voxelIndex(
                        CHUNK_SIZE,
                        local_pos[0],
                        local_pos[1],
                        local_pos[2],
                    )
                ] = .{ .id = id, .light_level = 0 };

                generateChunkBitfieldViews(cur.voxels, cur.bitfields);
            }

            chunk_slot.mesh_dirty = true;
            chunk_slot.markAdjacentChunkAsDirty(self);
        }
    }

    pub fn publishGenerationResult(
        self: *World,
        allocator: std.mem.Allocator,
        world: *World,
        res: GenerationResult,
    ) !void {
        errdefer {
            allocator.free(res.voxels);
            allocator.destroy(res.bitfield_views);
        }

        const slot = self.getChunkSlot(res.coord) orelse {
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

        slot.state = .generated;
        slot.markAdjacentChunkAsDirty(world);
    }

    pub fn publishMeshResult(
        self: *World,
        allocator: std.mem.Allocator,
        res: MeshResult,
    ) !void {
        const slot = self.getChunkSlot(res.coord) orelse {
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
};
