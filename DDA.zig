const std = @import("std");
const types = @import("types.zig");

const World = @import("world/World.zig").World;

const F3 = types.F3;
const I3 = types.I3;
const Face = types.Face;
const WorldVoxelCoord = types.WorldVoxelCoord;

inline fn isSolid(cell: I3, world: *World) bool {
    return world.getBlockIdFromWorldCoordinates(cell) != .air;
}

inline fn signStep(v: f32) i32 {
    if (v > 0.0) return 1;
    if (v < 0.0) return -1;
    return 0;
}

/// Solve equation for parameter t:
/// origin_x + t * direction_x = boundary_x (ray equation)
/// <=> t = (boundary_x - origin_x) / direction_x
fn computeInitialTMax(origin_axis: f32, dir_axis: f32, cell_axis: i32, step_axis: i32) f32 {
    if (step_axis == 0) return std.math.floatMax(f32);

    const boundary: f32 = if (step_axis > 0)
        @as(f32, @floatFromInt(cell_axis + 1))
    else
        @as(f32, @floatFromInt(cell_axis));

    return (boundary - origin_axis) / dir_axis;
}

// let dir_x = 0.5: the ray moves half a block per unit t.
// Then to move one full block in X, t_delta_x = 1/0.5 = 2
fn computeTDelta(dir_axis: f32) f32 {
    if (dir_axis == 0.0) return std.math.floatMax(f32);
    return 1.0 / @abs(dir_axis);
}

fn makeNormal(axis: usize, step: I3) I3 {
    var normal = I3{ 0, 0, 0 };
    normal[axis] = -step[axis];
    return normal;
}

// Let the axis be either X, Y, or Z
// step: whether the ray moves +1, -1, 0 along that axis
// t_max: the t value where the ray crosses a grid boundary along that axis
// t_delta: how much t_max increases every time we cross one voxel along that axis
pub fn raycastVoxel(origin: F3, dir: F3, max_distance: f32, world: *World) ?struct {
    cell: I3,
    normal: I3,
} {
    var cell: I3 = @intFromFloat(@floor(origin));

    const step = I3{ signStep(dir[0]), signStep(dir[1]), signStep(dir[2]) };
    var t_max = F3{
        computeInitialTMax(origin[0], dir[0], cell[0], step[0]),
        computeInitialTMax(origin[1], dir[1], cell[1], step[1]),
        computeInitialTMax(origin[2], dir[2], cell[2], step[2]),
    };
    const t_delta = F3{ computeTDelta(dir[0]), computeTDelta(dir[1]), computeTDelta(dir[2]) };

    var distance: f32 = 0;
    var normal = I3{ 0, 0, 0 };

    while (distance <= max_distance) {
        if (isSolid(cell, world)) return .{ .cell = cell, .normal = normal };

        if (t_max[0] < t_max[1]) {
            if (t_max[0] < t_max[2]) {
                cell[0] += step[0];
                distance = t_max[0];
                t_max[0] += t_delta[0];
                normal = makeNormal(0, step);
            } else {
                cell[2] += step[2];
                distance = t_max[2];
                t_max[2] += t_delta[2];
                normal = makeNormal(2, step);
            }
        } else {
            if (t_max[1] < t_max[2]) {
                cell[1] += step[1];
                distance = t_max[1];
                t_max[1] += t_delta[1];
                normal = makeNormal(1, step);
            } else {
                cell[2] += step[2];
                distance = t_max[2];
                t_max[2] += t_delta[2];
                normal = makeNormal(2, step);
            }
        }
    }

    return null;
}
