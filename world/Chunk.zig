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

pub const Voxel = struct {
    id: BlockId,
    /// 4 bits for block light, 4 bits for sky light  (0..15)
    light_level: u8,
};

//// CHUNKS ////////////////////////////////////////////////////////////////////

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
pub const ChunkSlot = struct {
    coord: ChunkCoord,
    gen: AtomicUsize = AtomicUsize.init(0),
    current: ?*ChunkVersion = null,

    world_min: ChunkCoord,
    world_max: ChunkCoord,

    state: ChunkState = .absent,
    edited: bool = false,

    mesh: ?*Mesh = null,
    mesh_dirty: bool = false,

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

    pub fn markAdjacentChunkAsDirty(self: *ChunkSlot, world: *World) void {
        const c = self.coord;
        const adjacent_coords = [_]ChunkCoord{
            .{ c[0] + 1, c[1], c[2] },
            .{ c[0] - 1, c[1], c[2] },
            .{ c[0], c[1] + 1, c[2] },
            .{ c[0], c[1] - 1, c[2] },
            .{ c[0], c[1], c[2] + 1 },
            .{ c[0], c[1], c[2] - 1 },
        };

        for (adjacent_coords) |coord| {
            if (world.getChunkSlot(coord)) |slot| {
                if (slot.current == null) continue;
                slot.mesh_dirty = true;
            }
        }
    }
};

/// Immutable after publishing
pub const ChunkVersion = struct {
    refs: AtomicU32 = AtomicU32.init(1), // one published reference held by the slot
    gen: usize,

    voxels: []const Voxel,
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

//// CHUNK LODS ////////////////////////////////////////////////////////////////

pub const LodTileCoord = @Vector(2, i32);

pub const LodTileVersion = struct {
    refs: AtomicU32 = AtomicU32.init(1),
    level: u8, // 0, 1, 2...
    coord: LodTileCoord,

    heights: []const i16, // grid vertices: (N + 1) * (N + 1)
    meterials: []const u8, // dominant/top material per cell N * N

    mesh: ?*Mesh = null,
};

pub const LodTileSlot = struct {
    level: u8,
    coord: LodTileCoord,
    current: ?*LodTileVersion = null,
    state: ChunkState = .absent,
    mesh_dirty: bool = false,
};
