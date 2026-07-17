const std = @import("std");
const types = @import("../types.zig");

const F3 = types.F3;
const I3 = types.I3;
const World = @import("../world/World.zig").World;
const PlayerConfig = @import("../EngineConfig.zig").EngineConfig.PlayerConfig;
const WorldConfig = @import("../EngineConfig.zig").EngineConfig.WorldConfig;

const EPS: f32 = 0.001;

inline fn isKnownSolid(world: *World, coord: I3) bool {
    const id = world.getBlockIdFromWorldCoordinates(coord);
    return id != .air and id != .unknown;
}

fn playerVolumeIsClear(world: *World, feet: F3, half_size: F3) bool {
    const min = F3{
        feet[0] - half_size[0],
        feet[1],
        feet[2] - half_size[2],
    };
    const max = F3{
        feet[0] + half_size[0],
        feet[1] + half_size[1] * 2.0,
        feet[2] + half_size[2],
    };

    const min_x: i32 = @intFromFloat(@floor(min[0]));
    const min_y: i32 = @intFromFloat(@floor(min[1]));
    const min_z: i32 = @intFromFloat(@floor(min[2]));

    const max_x: i32 = @intFromFloat(@floor(max[0] - EPS));
    const max_y: i32 = @intFromFloat(@floor(max[1] - EPS));
    const max_z: i32 = @intFromFloat(@floor(max[2] - EPS));

    var x = min_x;
    while (x <= max_x) : (x += 1) {
        var y = min_y;
        while (y <= max_y) : (y += 1) {
            var z = min_z;
            while (z <= max_z) : (z += 1) {
                if (world.getBlockIdFromWorldCoordinates(.{ x, y, z }) != .air)
                    return false;
            }
        }
    }

    return true;
}

fn hasKnownSupport(world: *World, feet: F3, half_size: F3) bool {
    const support_y: i32 = @intFromFloat(@floor(feet[1] - EPS));
    const min_x: i32 = @intFromFloat(@floor(feet[0] - half_size[0]));
    const max_x: i32 = @intFromFloat(@floor(feet[0] + half_size[0] - EPS));
    const min_z: i32 = @intFromFloat(@floor(feet[2] - half_size[2]));
    const max_z: i32 = @intFromFloat(@floor(feet[2] + half_size[2] - EPS));

    var x = min_x;
    while (x <= max_x) : (x += 1) {
        var z = min_z;
        while (z <= max_z) : (z += 1) {
            if (!isKnownSolid(world, .{ x, support_y, z })) return false;
        }
    }

    return true;
}

fn safeSpawnInColumn(
    world: *World,
    player_config: PlayerConfig,
    world_config: WorldConfig,
    x: i32,
    z: i32,
) ?F3 {
    var ground_y = world_config.max_world_y - 1;

    while (ground_y >= world_config.min_world_y) : (ground_y -= 1) {
        if (!isKnownSolid(world, .{ x, ground_y, z })) continue;

        const feet = F3{
            @as(f32, @floatFromInt(x)) + 0.5,
            @as(f32, @floatFromInt(ground_y + 1)) + EPS,
            @as(f32, @floatFromInt(z)) + 0.5,
        };

        if (playerVolumeIsClear(world, feet, player_config.half_size) and
            hasKnownSupport(world, feet, player_config.half_size))
        {
            return feet;
        }
    }

    return null;
}

/// Finds the nearest column around the origin with known solid support and a
/// completely generated, empty player collision volume.
pub fn findSafeSpawn(
    world: *World,
    player_config: PlayerConfig,
    world_config: WorldConfig,
    origin_x: i32,
    origin_z: i32,
    search_radius: i32,
) ?F3 {
    var radius: i32 = 0;

    while (radius <= search_radius) : (radius += 1) {
        var dz = -radius;
        while (dz <= radius) : (dz += 1) {
            var dx = -radius;
            while (dx <= radius) : (dx += 1) {
                if (radius != 0 and @abs(dx) != radius and @abs(dz) != radius)
                    continue;

                if (safeSpawnInColumn(
                    world,
                    player_config,
                    world_config,
                    origin_x + dx,
                    origin_z + dz,
                )) |spawn| return spawn;
            }
        }
    }

    return null;
}
