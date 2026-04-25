const std = @import("std");

const Voxel = @import("Chunk.zig").Voxel;

const VoxelQueued = struct {
    voxel: Voxel,
    world_pos: @Vector(3, i64),
};

pub const Lighting = struct {
    queue: std.ArrayList(VoxelQueued),
};
