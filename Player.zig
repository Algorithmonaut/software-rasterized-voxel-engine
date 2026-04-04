const std = @import("std");

const Camera = @import("Camera.zig").Camera;
const CameraConfig = @import("EngineConfig.zig").EngineConfig.CameraConfig;

const types = @import("math/types.zig");
const Vec3f = types.Vec3f;

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

    ground_accel: f32 = 80,
    air_accel: f32 = 20,

    ground_decel: f32 = 160,
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
        };
    }

    fn approachVec(current: Vec3f, target: Vec3f, max_delta: f32) Vec3f {
        const delta = target - current;
        const dist = vec.length(delta);

        if (dist <= max_delta or dist <= 0.000_001) return target;

        // Normalized delta direction
        const dir: Vec3f = delta / @as(Vec3f, @splat(dist));

        return .{
            current[0] + dir[0] * max_delta,
            0,
            current[2] + dir[2] * max_delta,
        };
    }

    pub fn update(self: *Player) void {
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

        const new_vel = approachVec(
            self.velocity,
            desired_velocity,
            rate * self.frame_inputs.dt,
        );

        self.velocity = new_vel;

        self.position += new_vel * @as(Vec3f, @splat(self.frame_inputs.dt));
        self.camera.from += new_vel * @as(Vec3f, @splat(self.frame_inputs.dt)); // set camera position
        self.camera.to = self.camera.from + forward; // set camera target
    }
};
