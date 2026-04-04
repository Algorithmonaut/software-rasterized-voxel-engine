const CameraConfig = @import("EngineConfig.zig").EngineConfig.CameraConfig;
const Player = @import("Player.zig").Player;
const FrameInput = @import("Player.zig").FrameInputs;

const std = @import("std");
const mat = @import("math/matrix.zig");
const vec = @import("math/vector.zig");
const Vec3f = @import("math/types.zig").Vec3f;

pub const Camera = struct {
    from: Vec3f,
    to: Vec3f,
    view_distance: f32,
    near: f32,
    fov: f32,
    speed: f32,
    sensivity: f32,

    view_mat: mat.Mat4f,
    proj_mat: mat.Mat4f,
    combined_mat: mat.Mat4f,

    yaw: f32,
    pitch: f32,

    pub const MoveKeys = struct {
        forward: bool = false,
        back: bool = false,
        right: bool = false,
        left: bool = false,
        up: bool = false,
        down: bool = false,
    };

    pub fn create(conf: CameraConfig, fb_width: usize, fb_height: usize) Camera {
        return .{
            .from = conf.from,
            .to = conf.to,
            .view_distance = conf.view_distance,
            .near = conf.near,
            .fov = conf.fov,
            .speed = conf.speed,
            .sensivity = conf.sensivity,
            .proj_mat = mat.create_projection_matrix(
                conf.fov,
                conf.view_distance,
                fb_width,
                fb_height,
                conf.near,
            ),

            .yaw = 0.0,
            .pitch = 0.0,
            .view_mat = undefined,
            .combined_mat = undefined,
        };
    }

    pub fn updateCameraTarget(
        self: *Camera,
        mouse_dx: i32,
        mouse_dy: i32,
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

        self.yaw = yaw;
        self.pitch = pitch;
    }
};
