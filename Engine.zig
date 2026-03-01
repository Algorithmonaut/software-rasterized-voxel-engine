const std = @import("std");
const Camera = @import("Camera.zig");
const Renderer = @import("Renderer.zig");

const cfg = @import("config.zig");
const Vec3f = cfg.Vec3f;

/// Owns global state
pub const Engine = struct {
    camera: Camera.Camera,
    renderer: Renderer.Renderer,

    pub fn init(allocator: std.mem.Allocator, camera_from: Vec3f, camera_to: Vec3f) Engine {
        const camera = Camera.Camera.init(camera_from, camera_to);
        const renderer = Renderer.Renderer.init(allocator) catch unreachable;

        return .{
            .camera = camera,
            .renderer = renderer,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.camera.deinit();
        self.renderer.deinit();
    }
};
