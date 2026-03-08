// NOTE: Refactored: YES

const std = @import("std");

const Camera = @import("Camera.zig").Camera;
const Renderer = @import("Renderer.zig").Renderer;
const FrameContext = @import("FrameContext.zig").FrameContext;
const SdlPlatform = @import("SdlPlatform.zig").SdlPlatform;
const SdlGraphics = @import("SdlGraphics.zig").SdlGraphics;
const EngineConfig = @import("EngineConfig.zig").EngineConfig;
const Atlas = @import("Atlas.zig").Atlas;
const TilePool = @import("tile.zig").TilePool;
const World = @import("World.zig").World;

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
    atlas: Atlas,
    world: World,

    pub fn init(allocator: std.mem.Allocator, conf: EngineConfig) !Engine {
        const tile_pool = try TilePool.init(allocator, conf.framebuffer_config);
        const platform = SdlPlatform.init();
        const graphics = try SdlGraphics.init(conf.framebuffer_config);
        const atlas = try Atlas.init(allocator, conf.atlas_config);
        const world = World.init(allocator, conf.world_config);
        const camera = Camera.init(
            conf.camera_config,
            conf.framebuffer_config.width,
            conf.framebuffer_config.height,
        );
        const renderer = Renderer.init(
            allocator,
            conf.framebuffer_config,
            tile_pool.tiles_count,
        ) catch unreachable;

        return .{
            .allocator = allocator,
            .camera = camera,
            .renderer = renderer,
            .platform = platform,
            .graphics = graphics,
            .tile_pool = tile_pool,
            .atlas = atlas,
            .world = world,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.camera.deinit();
        self.renderer.deinit(self.allocator);
        self.platform.deinit();
        self.graphics.deinit();
        self.atlas.deinit(self.allocator);
    }

    pub fn beginFrame(self: *Engine) !FrameContext {
        try self.renderer.begin_frame(self.allocator);
        const dt = self.platform.begin_frame();
        const framebuffer = try self.graphics.begin_frame();
        framebuffer.clear_black();

        return .{
            .dt = dt,
            .framebuffer = framebuffer,
        };
    }

    pub fn endFrame(self: *Engine, frame: *FrameContext) void {
        self.graphics.end_frame();
        self.graphics.present();
        _ = frame;
    }
};
