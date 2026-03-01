const std = @import("std");

const Camera = @import("Camera.zig").Camera;
const Renderer = @import("Renderer.zig").Renderer;
const FrameContext = @import("FrameContext.zig").FrameContext;
const SdlPlatform = @import("SdlPlatform.zig").SdlPlatform;

const cfg = @import("config.zig");
const Vec3f = cfg.Vec3f;

/// Owns global state
pub const Engine = struct {
    allocator: std.mem.Allocator,
    camera: Camera,
    renderer: Renderer,
    platform: SdlPlatform,

    pub fn init(allocator: std.mem.Allocator, camera_from: Vec3f, camera_to: Vec3f) Engine {
        const camera = Camera.init(camera_from, camera_to, 40);
        const renderer = Renderer.init(allocator) catch unreachable;
        const platform = SdlPlatform.init();
        return .{
            .allocator = allocator,
            .camera = camera,
            .renderer = renderer,
            .platform = platform,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.camera.deinit();
        self.renderer.deinit();
        self.platform.deinit();
    }

    pub fn begin_frame(self: *Engine) !FrameContext {
        try self.renderer.begin_frame(self.allocator);
        const dt = self.platform.begin_frame();

        return .{ .dt = dt };
    }

    pub fn end_frame(self: *Engine, frame: *FrameContext) void {
        _ = self;
        _ = frame;
    }
};
