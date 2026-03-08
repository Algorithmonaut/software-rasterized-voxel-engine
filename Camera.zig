// NOTE: Refactored: YES

const CameraConfig = @import("EngineConfig.zig").EngineConfig.CameraConfig;
const std = @import("std");
const mat = @import("math/matrix.zig");
const cfg = @import("config.zig");
const vec = @import("math/vector.zig");
const Vec3f = cfg.Vec3f;

pub const Camera = struct {
    from: Vec3f,
    to: Vec3f,
    view_distance: f32,
    fov: f32,
    speed: f32,
    sensivity: f32,

    view_mat: mat.Mat4f,
    proj_mat: mat.Mat4f,
    yaw: f32,
    pitch: f32,

    pub const MoveKeys = packed struct {
        forward: bool = false,
        back: bool = false,
        right: bool = false,
        left: bool = false,
        up: bool = false,
        down: bool = false,
    };

    pub fn init(conf: CameraConfig, fb_width: usize, fb_height: usize) Camera {
        return .{
            .from = conf.from,
            .to = conf.to,
            .view_distance = conf.view_distance,
            .fov = conf.fov,
            .speed = conf.speed,
            .sensivity = conf.sensivity,
            .proj_mat = mat.create_projection_matrix(
                conf.fov,
                conf.view_distance,
                fb_width,
                fb_height,
            ),

            .yaw = 0.0,
            .pitch = 0.0,
            .view_mat = undefined,
        };
    }

    pub fn deinit(self: *Camera) void {
        _ = self;
    }

    /// Update camera position and target from input
    pub fn update(
        self: *Camera,
        mouse_dx: i32,
        mouse_dy: i32,
        mov_keys: MoveKeys,
        dt: f32,
    ) void {
        // P: Update camera target
        const sens = self.sensivity;
        var yaw = self.yaw;
        var pitch = self.pitch;

        yaw -= @as(f32, @floatFromInt(mouse_dx)) * sens;
        pitch -= @as(f32, @floatFromInt(mouse_dy)) * sens;

        // Clamp pitch to avoid flipping at +-90°
        const max_pitch: f32 = 89.0 / 180.0 * std.math.pi;
        pitch = std.math.clamp(pitch, -max_pitch, max_pitch);

        // Already normalized
        const forward = Vec3f{
            @cos(pitch) * @sin(yaw),
            @sin(pitch),
            @cos(pitch) * @cos(yaw),
        };

        self.yaw = yaw;
        self.pitch = pitch;

        // P: Update camera position
        const step: f32 = self.speed * dt;
        const world_up = Vec3f{ 0, 1, 0 };

        var fwd_move = forward;
        fwd_move[1] = 0;
        fwd_move = vec.normalize(fwd_move); // no need to check for null, pitch is clamped

        const right = vec.cross_product(fwd_move, world_up);

        var wish = Vec3f{ 0, 0, 0 };
        if (mov_keys.forward) wish += fwd_move;
        if (mov_keys.back) wish -= fwd_move;
        if (mov_keys.right) wish += right;
        if (mov_keys.left) wish -= right;
        if (mov_keys.up) wish += world_up;
        if (mov_keys.down) wish -= world_up;

        // Normalize wish so diagonals aren't faster
        const wish_len2 = vec.dot_product(wish, wish);
        if (wish_len2 > 0) {
            wish = wish / @as(Vec3f, @splat(@sqrt(wish_len2)));
        }

        // NOTE: Camera position need to be set first
        // Camea position depends on camera target
        self.from += wish * @as(Vec3f, @splat(step)); // set camera position
        self.to = self.from + forward; // set camera target
    }
};
