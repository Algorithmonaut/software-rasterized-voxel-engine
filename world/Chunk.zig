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

pub const AtomicU32 = std.atomic.Value(u32);
pub const AtomicU8 = std.atomic.Value(u8);
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

/// Stable identity stored in World's hashmap
const ChunkSlot = struct {
    gen: AtomicUsize,
    current: std.atomic.Value(?*ChunkVersion),
    mesh: std.atomic.Value(?*Mesh),
};

/// Immutable after publishing
const ChunkVersion = struct {
    voxels: []const BlockId,
    bitfields: *const BitfieldViews,
};

pub const Chunk = struct {
    coord: ChunkCoord,
    voxels: []BlockId = undefined,
    mesh: *Mesh = undefined,
    bitfields: *BitfieldViews = undefined,

    world_min: ChunkCoord,
    world_max: ChunkCoord,

    state: ChunkState = .absent,
    dirty: bool = false,

    edited: bool = false,

    fn markAdjacentChunksAsDirty(c: ChunkCoord, world: *World) void {
        if (world.getChunk(.{ c[0] + 1, c[1], c[2] })) |a| a.dirty = true;
        if (world.getChunk(.{ c[0] - 1, c[1], c[2] })) |a| a.dirty = true;
        if (world.getChunk(.{ c[0], c[1] + 1, c[2] })) |a| a.dirty = true;
        if (world.getChunk(.{ c[0], c[1] - 1, c[2] })) |a| a.dirty = true;
        if (world.getChunk(.{ c[0], c[1], c[2] + 1 })) |a| a.dirty = true;
        if (world.getChunk(.{ c[0], c[1], c[2] - 1 })) |a| a.dirty = true;
    }

    pub fn create(
        allocator: std.mem.Allocator,
        coord: ChunkCoord,
    ) !Chunk {
        const size_vec = @as(ChunkCoord, @splat(CHUNK_SIZE));
        const world_min = coord * size_vec;
        const world_max = world_min + size_vec;

        const mesh = try allocator.create(Mesh);
        mesh.* = .{};

        const bitfields = try allocator.create(BitfieldViews);
        bitfields.* = std.mem.zeroInit(BitfieldViews, .{});

        return .{
            .coord = coord,
            .world_min = world_min,
            .world_max = world_max,
            .mesh = mesh,
            .bitfields = bitfields,
            .voxels = try allocator.alloc(BlockId, CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE),
        };
    }

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.voxels);
        allocator.destroy(self.bitfields);
        self.mesh.deinit(allocator);
        allocator.destroy(self.mesh);
        self.* = undefined;
    }
};
