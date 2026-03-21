const std = @import("std");
const Float = @import("math/types.zig").Float;
const BlockType = @import("Atlas.zig").BlockTypes;

const ChunkCoord = @import("math/types.zig").ChunkCoord;

const Block = @import("world/Block.zig");
const Quad = Block.Quad;
const BlockId = Block.BlockId;

const chunk_size = 32;
const Bitfield = u32; // TODO: Make the generation of this dependant on the chunk size

pub const BitfieldViews = struct {
    solid_x: [chunk_size][chunk_size]Bitfield, // [y][z], bits are x
    solid_y: [chunk_size][chunk_size]Bitfield, // [x][z], bits are y
    solid_z: [chunk_size][chunk_size]Bitfield, // [x][y], bits are z

    pub fn clearBitfields(self: *BitfieldViews) void {
        for (0..chunk_size) |a| {
            for (0..chunk_size) |b| {
                self.solid_x[a][b] = 0;
                self.solid_y[a][b] = 0;
                self.solid_z[a][b] = 0;
            }
        }
    }
};

pub const Chunk = struct {
    coord: ChunkCoord,

    dimensions: usize,

    voxels: []BlockId,

    dirty: bool = true,
    meshed: bool = false,

    mesh: std.ArrayList(Quad),

    // output of meshing
    face_count: usize = 0,

    bitfields: BitfieldViews,

    // aabb for culling
    world_min: ChunkCoord,
    world_max: ChunkCoord,

    pub fn generate(allocator: std.mem.Allocator, coord: ChunkCoord, size: usize) !Chunk {
        const size_i = @as(i32, @intCast(size));
        const size_vec = @as(ChunkCoord, @splat(size_i));

        const world_min = coord * size_vec;
        const world_max = world_min + size_vec;

        const voxels = try allocator.alloc(BlockId, size * size * size);

        for (0..voxels.len / size) |i| voxels[i] = @enumFromInt(i % 3);

        return .{
            .coord = coord,
            .voxels = voxels,

            .world_min = world_min,
            .world_max = world_max,
            .dimensions = size,
            .mesh = try std.ArrayList(Quad).initCapacity(allocator, 0),

            .bitfields = undefined,
        };
    }

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.voxels);
    }
};
