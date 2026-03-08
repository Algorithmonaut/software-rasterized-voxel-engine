const std = @import("std");
const Float = @import("math/types.zig").Float;
const BlockType = @import("Atlas.zig").BlockTypes;

const ChunkCoord = @import("math/types.zig").ChunkCoord;

pub const Chunk = struct {
    coord: ChunkCoord,

    dimensions: usize,

    voxels: []BlockType,

    dirty: bool = true,
    meshed: bool = false,

    // output of meshing
    face_count: usize = 0,

    // aabb for culling
    world_min: ChunkCoord,
    world_max: ChunkCoord,

    pub fn generate(allocator: std.mem.Allocator, coord: ChunkCoord, size: usize) !Chunk {
        const size_i = @as(i32, @intCast(size));
        const size_vec = @as(ChunkCoord, @splat(size_i));

        const world_min = coord * size_vec;
        const world_max = world_min + size_vec;

        const voxels = try allocator.alloc(BlockType, size * size * size);

        for (0..voxels.len) |i| voxels[i] = @enumFromInt(i % 3);

        return .{
            .coord = coord,
            .voxels = voxels,

            .world_min = world_min,
            .world_max = world_max,
            .dimensions = size,
        };
    }

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.voxels);
    }
};
