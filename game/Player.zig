const std = @import("std");
const types = @import("../types.zig");
const vec = @import("../math/vector.zig");
const constants = @import("../constants.zig");

const F3 = types.F3;
const BlockId = types.BlockId;
const DDA = @import("../DDA.zig");
const Camera = @import("Camera.zig").Camera;
const World = @import("../world/World.zig").World;
const CameraConfig = @import("../EngineConfig.zig").EngineConfig.CameraConfig;
const PlayerConfig = @import("../EngineConfig.zig").EngineConfig.PlayerConfig;

const AABB = struct {
    min: F3,
    max: F3,

    fn overlaps(a: AABB, b: AABB) bool {
        return a.max[0] > b.min[0] and a.min[0] < b.max[0] and
            a.max[1] > b.min[1] and a.min[1] < b.max[1] and
            a.max[2] > b.min[2] and a.min[2] < b.max[2];
    }
};

pub const FrameInputs = struct {
    forward: bool = false,
    back: bool = false,
    right: bool = false,
    left: bool = false,
    up: bool = false,
    down: bool = false,
    break_block: bool = false,
    place_block: bool = false,

    mouse_dx: i32 = 0,
    mouse_dy: i32 = 0,

    dt: f32 = 0,
};

pub const Player = struct {
    /// Feet position
    velocity: F3 = .{ 0.0, 0.0, 0.0 },
    grounded: bool = false,

    camera: Camera,

    frame_inputs: FrameInputs,

    position: F3,
    half_size: F3,

    speed: f32,

    ground_accel: f32,
    ground_decel: f32,
    air_accel: f32,
    air_decel: f32,

    gravity: f32,
    jump_speed: f32,

    fn playerAABB(self: *Player) AABB {
        const position = self.position;
        const half_size = self.half_size;

        return .{
            .min = .{
                position[0] - half_size[0],
                position[1],
                position[2] - half_size[2],
            },

            .max = .{
                position[0] + half_size[0],
                position[1] + half_size[1] * 2,
                position[2] + half_size[2],
            },
        };
    }

    pub fn init(
        conf: PlayerConfig,
        cam_conf: CameraConfig,
        fb_width: usize,
        fb_height: usize,
    ) Player {
        const camera = Camera.create(cam_conf, fb_width, fb_height);

        return .{
            .camera = camera,
            .frame_inputs = .{},

            .position = conf.initial_position,
            .half_size = conf.half_size,
            .speed = conf.speed,

            .air_accel = conf.air_accel,
            .air_decel = conf.air_decel,
            .ground_accel = conf.ground_accel,
            .ground_decel = conf.ground_decel,

            .gravity = conf.gravity,
            .jump_speed = conf.jump_speed,
        };
    }

    fn approachHorizontal(current: F3, target: F3, max_delta: f32) F3 {
        const delta = F3{
            target[0] - current[0],
            0,
            target[2] - current[2],
        };

        const dist = @sqrt(delta[0] * delta[0] + delta[2] * delta[2]);

        if (dist <= max_delta or dist <= 0.000001) {
            return .{ target[0], current[1], target[2] };
        }

        const inv = 1.0 / dist;
        return .{
            current[0] + delta[0] * inv * max_delta,
            current[1],
            current[2] + delta[2] * inv * max_delta,
        };
    }

    //// RESOLVE MOVEMENT AND COLLISIONS FOR EACH AXIS //////////////////////////

    inline fn getBlockAABB(x: i32, y: i32, z: i32) AABB {
        return .{
            .min = F3{
                @floatFromInt(x),
                @floatFromInt(y),
                @floatFromInt(z),
            },
            .max = F3{
                @floatFromInt(x + 1),
                @floatFromInt(y + 1),
                @floatFromInt(z + 1),
            },
        };
    }

    fn moveX(self: *Player, world: *World, dx: f32) !void {
        if (dx == 0) return;

        const eps: f32 = 0.001;

        self.position[0] += dx;

        var box = self.playerAABB();

        const min_x: i32 = @intFromFloat(@floor(box.min[0]));
        const min_y: i32 = @intFromFloat(@floor(box.min[1]));
        const min_z: i32 = @intFromFloat(@floor(box.min[2]));

        const max_x: i32 = @intFromFloat(@floor(box.max[0] - eps));
        const max_y: i32 = @intFromFloat(@floor(box.max[1] - eps));
        const max_z: i32 = @intFromFloat(@floor(box.max[2] - eps));

        var x: i32 = min_x;
        while (x <= max_x) : (x += 1) {
            var y: i32 = min_y;
            while (y <= max_y) : (y += 1) {
                var z: i32 = min_z;
                while (z <= max_z) : (z += 1) {
                    const block_id = world.getBlockIdFromWorldCoordinates(
                        .{ x, y, z },
                    );

                    if (block_id == BlockId.air)
                        continue;

                    const block_aabb = getBlockAABB(x, y, z);

                    if (box.overlaps(block_aabb)) {
                        if (dx > 0)
                            self.position[0] = @as(f32, @floatFromInt(x)) - self.half_size[0] - eps
                        else
                            self.position[0] = @as(f32, @floatFromInt(x + 1)) + self.half_size[0] + eps;

                        self.velocity[0] = 0;
                        return;
                    }
                }
            }
        }
    }

    fn moveZ(self: *Player, world: *World, dz: f32) !void {
        if (dz == 0) return;

        const eps: f32 = 0.001;

        self.position[2] += dz;

        var box = self.playerAABB();

        const min_x: i32 = @intFromFloat(@floor(box.min[0]));
        const min_y: i32 = @intFromFloat(@floor(box.min[1]));
        const min_z: i32 = @intFromFloat(@floor(box.min[2]));

        const max_x: i32 = @intFromFloat(@floor(box.max[0] - eps));
        const max_y: i32 = @intFromFloat(@floor(box.max[1] - eps));
        const max_z: i32 = @intFromFloat(@floor(box.max[2] - eps));

        var x: i32 = min_x;
        while (x <= max_x) : (x += 1) {
            var y: i32 = min_y;
            while (y <= max_y) : (y += 1) {
                var z: i32 = min_z;
                while (z <= max_z) : (z += 1) {
                    const block_id = world.getBlockIdFromWorldCoordinates(
                        .{ x, y, z },
                    );

                    if (block_id == BlockId.air) continue;

                    const block_aabb = getBlockAABB(x, y, z);

                    if (box.overlaps(block_aabb)) {
                        if (dz > 0)
                            self.position[2] = @as(f32, @floatFromInt(z)) - self.half_size[2] - eps
                        else
                            self.position[2] = @as(f32, @floatFromInt(z + 1)) + self.half_size[2] + eps;

                        self.velocity[2] = 0;
                        return;
                    }
                }
            }
        }
    }

    fn moveY(self: *Player, world: *World, dy: f32) !void {
        if (dy == 0) return;

        const eps: f32 = 0.001;

        self.position[1] += dy;

        var box = self.playerAABB();

        const min_x: i32 = @intFromFloat(@floor(box.min[0]));
        const min_y: i32 = @intFromFloat(@floor(box.min[1]));
        const min_z: i32 = @intFromFloat(@floor(box.min[2]));

        const max_x: i32 = @intFromFloat(@floor(box.max[0] - eps));
        const max_y: i32 = @intFromFloat(@floor(box.max[1] - eps));
        const max_z: i32 = @intFromFloat(@floor(box.max[2] - eps));

        var x: i32 = min_x;
        while (x <= max_x) : (x += 1) {
            var y: i32 = min_y;
            while (y <= max_y) : (y += 1) {
                var z: i32 = min_z;
                while (z <= max_z) : (z += 1) {
                    const block_id = world.getBlockIdFromWorldCoordinates(
                        .{ x, y, z },
                    );

                    if (block_id == BlockId.air) {
                        continue;
                    }

                    const block_aabb = getBlockAABB(x, y, z);

                    if (box.overlaps(block_aabb)) {
                        if (dy > 0)
                            self.position[1] = @as(f32, @floatFromInt(y)) - self.half_size[1] * 2 - eps
                        else {
                            self.position[1] = @as(f32, @floatFromInt(y + 1)) + eps;
                            self.grounded = true;
                        }

                        self.velocity[1] = 0;
                        return;
                    }
                }
            }
        }
    }

    pub fn update(self: *Player, world: *World) !void {
        self.camera.updateCameraTarget(
            self.frame_inputs.mouse_dx,
            self.frame_inputs.mouse_dy,
        );

        // TODO: Move speed from camera to player

        // Compute desired horizontal velocity from input
        const world_up = F3{ 0, 1, 0 };

        // Already normalized
        const forward = F3{
            @cos(self.camera.pitch) * @sin(self.camera.yaw),
            @sin(self.camera.pitch),
            @cos(self.camera.pitch) * @cos(self.camera.yaw),
        };

        var fwd_move = forward;
        fwd_move[1] = 0; // ignore y position
        fwd_move = vec.normalize(fwd_move);

        const right = vec.cross_product(fwd_move, world_up);

        var wish = F3{ 0, 0, 0 };
        if (self.frame_inputs.forward) wish += fwd_move;
        if (self.frame_inputs.back) wish -= fwd_move;
        if (self.frame_inputs.right) wish += right;
        if (self.frame_inputs.left) wish -= right;
        // if (self.frame_inputs.up) wish += world_up;
        // if (self.frame_inputs.down) wish -= world_up;

        // Normalize wish so diagonals aren't faster
        const wish_len2 = vec.dot_product(wish, wish);
        if (wish_len2 > 0)
            wish = wish / @as(F3, @splat(@sqrt(wish_len2)));

        const has_input = wish_len2 > 0.0;

        const rate = if (has_input)
            (if (self.grounded) self.ground_accel else self.air_accel)
        else
            (if (self.grounded) self.ground_decel else self.air_decel);

        // desired_velocity is a velocity in units per second
        const desired_velocity = wish * @as(F3, @splat(self.speed));

        var new_vel = approachHorizontal(
            self.velocity,
            desired_velocity,
            rate * self.frame_inputs.dt,
        );

        new_vel[1] -= self.gravity * self.frame_inputs.dt;

        if (self.grounded and self.frame_inputs.up) {
            new_vel[1] = self.jump_speed;
            self.grounded = false;
        }

        self.velocity = new_vel;

        const delta = self.velocity * @as(F3, @splat(self.frame_inputs.dt));

        self.grounded = false;
        try self.moveX(world, delta[0]);
        try self.moveY(world, delta[1]);
        try self.moveZ(world, delta[2]);

        // self.position += new_vel * @as(Vec3f, @splat(self.frame_inputs.dt));
        const camera_height = F3{ 0, 1.8, 0 };
        self.camera.from = self.position + camera_height; // set camera position
        self.camera.to = self.camera.from + forward; // set camera target

        const dir_normalized = -vec.normalize(self.camera.from - self.camera.to);

        if (self.frame_inputs.break_block) {
            self.frame_inputs.break_block = false;
            const result = DDA.raycastVoxel(self.camera.from, dir_normalized, 80000, world);

            if (result) |res| world.setBlockIdFromWorldCoordinates(res.cell, .air);
        }

        if (self.frame_inputs.place_block) {
            self.frame_inputs.place_block = false;
            const result = DDA.raycastVoxel(self.camera.from, dir_normalized, 80000, world);

            if (result) |res| {
                const coord = res.cell + res.normal;

                var box = self.playerAABB();
                if (box.overlaps(getBlockAABB(coord[0], coord[1], coord[2]))) return;

                world.setBlockIdFromWorldCoordinates(coord, .stone);
            }
        }
    }
};
