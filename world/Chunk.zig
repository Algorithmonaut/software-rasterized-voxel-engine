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

pub const ChunkState = enum(u8) {
    absent,
    generating,
    generated,
    meshing,
    ready,
};

pub const Bitfield = u32;

pub const BitfieldViews = struct {
    solid_x: [CHUNK_SIZE][CHUNK_SIZE]Bitfield, // [y][z], bits are x
    solid_y: [CHUNK_SIZE][CHUNK_SIZE]Bitfield, // [x][z], bits are y
    solid_z: [CHUNK_SIZE][CHUNK_SIZE]Bitfield, // [x][y], bits are z
};

pub fn createBitfields(voxels: []const BlockId) BitfieldViews {
    std.debug.assert(voxels.len == VOXEL_COUNT);

    var bitfields_out = std.mem.zeroInit(BitfieldViews, .{});

    for (0..CHUNK_SIZE) |x_usize| {
        const x: u5 = @intCast(x_usize);
        const mx: u32 = @as(u32, 1) << x;

        for (0..CHUNK_SIZE) |y_usize| {
            const y: u5 = @intCast(y_usize);
            const my: u32 = @as(u32, 1) << y;

            for (0..CHUNK_SIZE) |z_usize| {
                const z: u5 = @intCast(z_usize);
                const mz: u32 = @as(u32, 1) << z;

                const idx = voxelIndex(CHUNK_SIZE, x_usize, y_usize, z_usize);
                if (voxels[idx] == .air) continue;

                bitfields_out.solid_x[y_usize][z_usize] |= mx;
                bitfields_out.solid_y[x_usize][z_usize] |= my;
                bitfields_out.solid_z[x_usize][y_usize] |= mz;
            }
        }
    }

    return bitfields_out;
}

pub const Chunk = struct {
    coord: ChunkCoord,
    voxels: []BlockId,
    mesh: *Mesh,
    bitfields: BitfieldViews = undefined,

    world_min: ChunkCoord,
    world_max: ChunkCoord,

    state: ChunkState = .absent,
    dirty: bool = false,

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

        return .{
            .coord = coord,
            .world_min = world_min,
            .world_max = world_max,
            .mesh = mesh,
            .voxels = try allocator.alloc(BlockId, CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE),
        };
    }

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.voxels);
        self.mesh.deinit(allocator);
        allocator.destroy(self.mesh);
        self.* = undefined;
    }
};
