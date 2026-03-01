// NOTE: Refactored: YES

const std = @import("std");

const Camera = @import("Camera.zig").Camera;
const Renderer = @import("Renderer.zig").Renderer;
const FrameContext = @import("FrameContext.zig").FrameContext;
const SdlPlatform = @import("SdlPlatform.zig").SdlPlatform;
const SdlGraphics = @import("SdlGraphics.zig").SdlGraphics;

const cfg = @import("config.zig");
const Vec3f = cfg.Vec3f;

/// Owns global state
pub const Engine = struct {
    allocator: std.mem.Allocator,
    camera: Camera,
    renderer: Renderer,
    platform: SdlPlatform,
    graphics: SdlGraphics,

    pub fn init(allocator: std.mem.Allocator, camera_from: Vec3f, camera_to: Vec3f) !Engine {
        const camera = Camera.init(camera_from, camera_to, 40);
        const renderer = Renderer.init(allocator) catch unreachable;
        const platform = SdlPlatform.init();
        const graphics = try SdlGraphics.init();
        return .{
            .allocator = allocator,
            .camera = camera,
            .renderer = renderer,
            .platform = platform,
            .graphics = graphics,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.camera.deinit();
        self.renderer.deinit();
        self.platform.deinit();
        self.graphics.deinit();
    }

    pub fn begin_frame(self: *Engine) !FrameContext {
        try self.renderer.begin_frame(self.allocator);
        const dt = self.platform.begin_frame();
        const framebuffer = try self.graphics.begin_frame();
        framebuffer.clear_black();

        return .{
            .dt = dt,
            .framebuffer = framebuffer,
        };
    }

    pub fn end_frame(self: *Engine, frame: *FrameContext) void {
        self.graphics.end_frame();
        self.graphics.present();
        _ = frame;
    }
};
