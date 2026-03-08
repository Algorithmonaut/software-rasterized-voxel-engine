const std = @import("std");
const t = @import("math/types.zig");
const Cube = @import("Cube.zig").Cube;
const BlockType = @import("Atlas.zig").BlockTypes;

const chunck_size = 16;

pub const Chunck = struct {
    coord: @Vector(3, t.Int),

    dimensions: usize,

    voxels: []BlockType,

    dirty: bool = true,
    meshed: bool = false,

    // output of meshing
    face_count: usize = 0,

    // aabb for culling
    world_min: @Vector(3, t.Int),
    world_max: @Vector(3, t.Int),

    pub fn generate(allocator: std.mem.Allocator, coord: @Vector(3, t.Int)) !Chunck {
        const world_min = coord * @as(@Vector(3, t.Int), @splat(chunck_size));
        const world_max = world_min + @as(@Vector(3, t.Int), @splat(chunck_size));

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
};
