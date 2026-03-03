// NOTE: Refactored: YES

const std = @import("std");

const Camera = @import("Camera.zig").Camera;
const Renderer = @import("Renderer.zig").Renderer;
const FrameContext = @import("FrameContext.zig").FrameContext;
const SdlPlatform = @import("SdlPlatform.zig").SdlPlatform;
const SdlGraphics = @import("SdlGraphics.zig").SdlGraphics;
const EngineConfig = @import("./engine/EngineConfig.zig").EngineConfig;

const TilePool = @import("tile.zig").TilePool;

const cfg = @import("config.zig");
const Vec3f = cfg.Vec3f;

/// Owns global state
pub const Engine = struct {
    allocator: std.mem.Allocator,
    camera: Camera,
    renderer: Renderer,
    platform: SdlPlatform,
    graphics: SdlGraphics,
    tile_pool: TilePool,

    pub fn init(allocator: std.mem.Allocator, conf: EngineConfig) !Engine {
        const camera = Camera.init(conf.camera_config);
        const renderer = Renderer.init(allocator, conf.framebuffer_config) catch unreachable;
        const platform = SdlPlatform.init();
        const graphics = try SdlGraphics.init(conf.framebuffer_config);
        const tile_pool = try TilePool.init(allocator, conf.framebuffer_config);

        return .{
            .allocator = allocator,
            .camera = camera,
            .renderer = renderer,
            .platform = platform,
            .graphics = graphics,
            .tile_pool = tile_pool,
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
