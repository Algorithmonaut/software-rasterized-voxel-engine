// NOTE: Refactored: YES

const std = @import("std");

const Camera = @import("Camera.zig").Camera;
const Renderer = @import("Renderer.zig").Renderer;
const FrameContext = @import("FrameContext.zig").FrameContext;
const SdlPlatform = @import("platform/SdlPlatform.zig").SdlPlatform;
const SdlGraphics = @import("platform/SdlGraphics.zig").SdlGraphics;
const EngineConfig = @import("EngineConfig.zig").EngineConfig;
const Atlas = @import("Atlas.zig").Atlas;
const TilePool = @import("tile.zig").TilePool;
const World = @import("World.zig").World;
const TriangleRasterizer = @import("renderer/TrianglesRasterizer.zig").TrianglesRasterizer;
const TerrainGenerator = @import("world/TerrainGenerator.zig").TerrainGenerator;
const Mesher = @import("world/Mesher.zig").Mesher;

const Vec3f = @import("math/types.zig").Vec3f;

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
    triangle_rasterizer: TriangleRasterizer,
    terrain_generator: TerrainGenerator,
    mesher: *Mesher,

    pub fn init(allocator: std.mem.Allocator, conf: EngineConfig) !Engine {
        const tile_pool = try TilePool.init(allocator, conf.framebuffer_config);
        const platform = SdlPlatform.init();
        const graphics = try SdlGraphics.init(conf.framebuffer_config);
        const atlas = try Atlas.init(allocator, conf.atlas_config);
        const world = World.init(allocator);
        const triangle_rasterizer = try TriangleRasterizer.init(allocator, tile_pool.count);

        const mesher = try allocator.create(Mesher);
        mesher.* = try Mesher.init(allocator);
        try mesher.start();

        const terrain_generator = TerrainGenerator.init(conf.world_config);
        const camera = Camera.init(
            conf.camera_config,
            conf.framebuffer_config.width,
            conf.framebuffer_config.height,
        );
        const renderer = try Renderer.init(
            allocator,
            conf.framebuffer_config,
            conf.camera_config.view_distance,
        );

        return Engine{
            .allocator = allocator,
            .camera = camera,
            .renderer = renderer,
            .platform = platform,
            .graphics = graphics,
            .tile_pool = tile_pool,
            .atlas = atlas,
            .world = world,
            .triangle_rasterizer = triangle_rasterizer,
            .terrain_generator = terrain_generator,
            .mesher = mesher,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.mesher.stop();
        self.mesher.deinit();
        self.world.deinit();

        self.camera.deinit();
        self.renderer.deinit(self.allocator);
        self.platform.deinit();
        self.graphics.deinit();
        self.atlas.deinit(self.allocator);
        self.triangle_rasterizer.deinit(self.allocator);
        self.terrain_generator.deinit();
    }

    pub fn beginFrame(self: *Engine) !FrameContext {
        self.renderer.beginFrame();
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
