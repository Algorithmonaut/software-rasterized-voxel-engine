const std = @import("std");
const Float = @import("math/types.zig").Float;
const BlockType = @import("Atlas.zig").BlockTypes;

const ChunkCoord = @import("math/types.zig").ChunkCoord;

const chunck_size = 16;

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

    pub fn generate(allocator: std.mem.Allocator, coord: ChunkCoord) !Chunk {
        const world_min = coord * @as(ChunkCoord, @splat(chunck_size));
        const world_max = world_min + @as(ChunkCoord, @splat(chunck_size));

        const voxels = try allocator.alloc(BlockType, chunck_size * chunck_size * chunck_size);

        for (0..voxels.len) |i| voxels[i] = @enumFromInt(i % 3);

        return .{
            .coord = coord,
            .voxels = voxels,

            .world_min = world_min,
            .world_max = world_max,
            .dimensions = chunck_size,
        };
    }

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.voxels);
    }
};
