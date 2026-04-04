const std = @import("std");

const Camera = @import("Camera.zig").Camera;
const CameraConfig = @import("EngineConfig.zig").EngineConfig.CameraConfig;

const World = @import("World.zig").World;
const Chunk = @import("Chunk.zig").Chunk;

const BlockId = @import("world/Block.zig").BlockId;

const types = @import("math/types.zig");
const Vec3f = types.Vec3f;
const Vec3i = types.Vec3i;

const vec = @import("math/vector.zig");

const AABB = struct {
    min: Vec3f,
    max: Vec3f,

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

    mouse_dx: i32 = 0,
    mouse_dy: i32 = 0,

    dt: f32 = 0,
};

pub const Player = struct {
    /// Feet position
    position: Vec3f,
    velocity: Vec3f = .{ 0.0, 0.0, 0.0 },
    half_size: Vec3f,
    grounded: bool = true,

    aabb: AABB,

    camera: Camera,

    frame_inputs: FrameInputs,

    ground_accel: f32 = 120,
    air_accel: f32 = 20,

    ground_decel: f32 = 240,
    air_decel: f32 = 40,

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

    pub fn init(conf: CameraConfig, fb_width: usize, fb_height: usize) Player {
        const camera = Camera.create(conf, fb_width, fb_height);

        return .{
            .position = .{ 0.0, 60.0 - 1.8, 0.0 },
            .half_size = .{ 0.3, 0.9, 0.3 },

            .camera = camera,

            .frame_inputs = .{},

            .aabb = undefined,
        };
    }

    fn approachHorizontal(current: Vec3f, target: Vec3f, max_delta: f32) Vec3f {
        const delta = Vec3f{
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

    fn moveX(self: *Player, world: *World, dx: f32) !void {
        if (dx == 0) return;

        const eps: f32 = 0.001;
        const chunk_size: i32 = 32;

        self.position[0] += dx;

        var box = self.playerAABB();

        const min_x: i32 = @intFromFloat(@floor(box.min[0]));
        const min_y: i32 = @intFromFloat(@floor(box.min[1]));
        const min_z: i32 = @intFromFloat(@floor(box.min[2]));

        const max_x: i32 = @intFromFloat(@floor(box.max[0] - eps));
        const max_y: i32 = @intFromFloat(@floor(box.max[1] - eps));
        const max_z: i32 = @intFromFloat(@floor(box.max[2] - eps));

        var cached_chunk: ?*Chunk = null;
        var cached_chunk_pos: Vec3i = undefined;

        var x: i32 = min_x;
        while (x <= max_x) : (x += 1) {
            var y: i32 = min_y;
            while (y <= max_y) : (y += 1) {
                var z: i32 = min_z;
                while (z <= max_z) : (z += 1) {
                    const chunk_pos = Vec3i{
                        @divFloor(x, chunk_size),
                        @divFloor(y, chunk_size),
                        @divFloor(z, chunk_size),
                    };

                    const chunk = blk: {
                        if (cached_chunk) |c| {
                            if (@reduce(.And, cached_chunk_pos == chunk_pos)) {
                                break :blk c;
                            }
                        }

                        const c = world.getChunk(chunk_pos) orelse continue;
                        cached_chunk = c;
                        cached_chunk_pos = chunk_pos;
                        break :blk c;
                    };

                    const local_pos = Vec3i{
                        @mod(x, chunk_size),
                        @mod(y, chunk_size),
                        @mod(z, chunk_size),
                    };

                    const index: i32 =
                        local_pos[0] +
                        local_pos[1] * chunk_size +
                        local_pos[2] * chunk_size * chunk_size;

                    if (chunk.voxels[@as(usize, @intCast(index))] == BlockId.air)
                        continue;

                    const block_aabb = AABB{
                        .min = Vec3f{
                            @floatFromInt(x),
                            @floatFromInt(y),
                            @floatFromInt(z),
                        },
                        .max = Vec3f{
                            @floatFromInt(x + 1),
                            @floatFromInt(y + 1),
                            @floatFromInt(z + 1),
                        },
                    };

                    if (box.overlaps(block_aabb)) {
                        std.debug.print(
                            "X collision with voxel ({}, {}, {})\n",
                            .{ x, y, z },
                        );

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
    pub fn update(self: *Player, world: *World) !void {
        self.camera.updateCameraTarget(
            self.frame_inputs.mouse_dx,
            self.frame_inputs.mouse_dy,
        );

        // TODO: Move speed from camera to player

        // Compute desired horizontal velocity from input
        const world_up = Vec3f{ 0, 1, 0 };

        // Already normalized
        const forward = Vec3f{
            @cos(self.camera.pitch) * @sin(self.camera.yaw),
            @sin(self.camera.pitch),
            @cos(self.camera.pitch) * @cos(self.camera.yaw),
        };

        var fwd_move = forward;
        fwd_move[1] = 0; // ignore y position
        fwd_move = vec.normalize(fwd_move);

        const right = vec.cross_product(fwd_move, world_up);

        var wish = Vec3f{ 0, 0, 0 };
        if (self.frame_inputs.forward) wish += fwd_move;
        if (self.frame_inputs.back) wish -= fwd_move;
        if (self.frame_inputs.right) wish += right;
        if (self.frame_inputs.left) wish -= right;
        if (self.frame_inputs.up) wish += world_up;
        if (self.frame_inputs.down) wish -= world_up;

        // Normalize wish so diagonals aren't faster
        const wish_len2 = vec.dot_product(wish, wish);
        if (wish_len2 > 0)
            wish = wish / @as(Vec3f, @splat(@sqrt(wish_len2)));

        const has_input = wish_len2 > 0.0;

        const rate = if (has_input)
            (if (self.grounded) self.ground_accel else self.air_accel)
        else
            (if (self.grounded) self.ground_decel else self.air_decel);

        // desired_velocity is a velocity in units per second
        const move_speed: f32 = self.camera.speed;
        const desired_velocity = wish * @as(Vec3f, @splat(move_speed));

        const new_vel = approachHorizontal(
            self.velocity,
            desired_velocity,
            rate * self.frame_inputs.dt,
        );

        self.velocity = new_vel;

        const delta = self.velocity * @as(Vec3f, @splat(self.frame_inputs.dt));

        try self.moveX(world, delta[0]);

        // self.position += new_vel * @as(Vec3f, @splat(self.frame_inputs.dt));
        self.camera.from = self.position; // set camera position
        self.camera.to = self.camera.from + forward; // set camera target
    }
};
