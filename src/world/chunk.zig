const std = @import("std");
const types = @import("../types.zig");
const constants = @import("../constants.zig");

const Block = types.Block;
const BlockId = types.BlockId;
const ChunkCoord = types.ChunkCoord;
const ChunkState = types.ChunkState;
const World = @import("World.zig").World;
const BitfieldViews = types.BitfieldViews;
const Mesh = @import("../mesh/Mesh.zig").Mesh;

pub const AtomicU8 = std.atomic.Value(u8);
pub const AtomicU32 = std.atomic.Value(u32);
pub const LodLevel = u8;

pub const AtomicUsize = std.atomic.Value(usize);

const CHUNK_SIZE = constants.CHUNK_SIZE;

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

    voxels: []Block, // This should be const ??
    // TODO: Rename to bitfieldViews
    bitfields: *BitfieldViews, // This should be const??

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
