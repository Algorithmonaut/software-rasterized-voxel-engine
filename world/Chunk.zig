const std = @import("std");

const ChunkCoord = @import("../math/types.zig").ChunkCoord;
const World = @import("World.zig").World;

const Block = @import("Block.zig");
const BlockId = Block.BlockId;
const Mesh = @import("../mesh/Mesh.zig").Mesh;

pub const CHUNK_SIZE = 32;
pub const VOXEL_COUNT = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;

inline fn voxelIndex(size: usize, x: usize, y: usize, z: usize) usize {
    return x + y * size + z * size * size;
}

pub const AtomicU8 = std.atomic.Value(u8);
pub const AtomicU32 = std.atomic.Value(u32);
pub const LodLevel = u8;

pub const AtomicUsize = std.atomic.Value(usize);

pub const ChunkState = enum(u8) {
    absent,
    generating,
    generated,
    meshing,
    ready,
};

pub const Bitfield = u32;
pub const Bitfields = [CHUNK_SIZE][CHUNK_SIZE]Bitfield;

pub const BitfieldViews = struct {
    solid_x: Bitfields, // [y][z], bits are x
    solid_y: Bitfields, // [x][z], bits are y
    solid_z: Bitfields, // [x][y], bits are z
};

// fn markAdjacentChunksAsDirty(c: ChunkCoord, world: *World) void {
//     if (world.getChunk(.{ c[0] + 1, c[1], c[2] })) |a| a.dirty = true;
//     if (world.getChunk(.{ c[0] - 1, c[1], c[2] })) |a| a.dirty = true;
//     if (world.getChunk(.{ c[0], c[1] + 1, c[2] })) |a| a.dirty = true;
//     if (world.getChunk(.{ c[0], c[1] - 1, c[2] })) |a| a.dirty = true;
//     if (world.getChunk(.{ c[0], c[1], c[2] + 1 })) |a| a.dirty = true;
//     if (world.getChunk(.{ c[0], c[1], c[2] - 1 })) |a| a.dirty = true;
// }

/// Stable identity stored in World's hashmap
pub const ChunkSlot = struct {
    coord: ChunkCoord,
    gen: AtomicUsize = AtomicUsize.init(0),
    current: ?*ChunkVersion = null,

    world_min: ChunkCoord,
    world_max: ChunkCoord,

    state: ChunkState = .absent,
    edited: bool = false,

    mesh: ?*Mesh = null,

    pub fn create(coord: ChunkCoord) ChunkSlot {
        const size_vec = @as(ChunkCoord, @splat(CHUNK_SIZE));
        const world_min = coord * size_vec;
        const world_max = world_min + size_vec;

        return .{ .coord = coord, .world_min = world_min, .world_max = world_max };
    }

    pub fn destroy(self: *ChunkSlot, allocator: std.mem.Allocator) void {
        if (self.current) |cur| cur.releaseVersion(allocator);
        if (self.mesh) |m| {
            m.deinit(allocator);
            allocator.destroy(m);
        }
    }
};

/// Immutable after publishing
pub const ChunkVersion = struct {
    refs: AtomicU32 = AtomicU32.init(1), // one published reference held by the slot
    gen: usize,

    voxels: []const BlockId,
    // TODO: Rename to bitfieldViews
    bitfields: *const BitfieldViews,

    pub fn retainVersion(self: *ChunkVersion) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }

    pub fn releaseVersion(self: *ChunkVersion, allocator: std.mem.Allocator) void {
        const prev = self.refs.fetchSub(1, .acq_rel);
        if (prev == 1) {
            allocator.free(self.voxels);
            allocator.destroy(@constCast(self.bitfields));
            allocator.destroy(self);
        }
    }
};
