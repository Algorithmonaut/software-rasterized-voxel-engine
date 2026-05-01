const std = @import("std");
const types = @import("types.zig");

const F3 = types.F3;
const FrameContext = types.FrameContext;
const Text = @import("UI/Text.zig").Text;
const Atlas = @import("Atlas.zig").Atlas;
const TilePool = @import("tile.zig").TilePool;
const World = @import("world/World.zig").World;
const Player = @import("game/Player.zig").Player;
const Renderer = @import("Renderer.zig").Renderer;
const EngineConfig = @import("EngineConfig.zig").EngineConfig;
const Rasterizer = @import("renderer/Rasterizer.zig").Rasterizer;
const ChunkWorker = @import("world/ChunkWorker.zig").ChunkWorker;
const SdlPlatform = @import("platform/SdlPlatform.zig").SdlPlatform;
const SdlGraphics = @import("platform/SdlGraphics.zig").SdlGraphics;
const ChunkManager = @import("world/ChunkManager.zig").ChunkManager;
const TerrainGenerator = @import("world/TerrainGenerator.zig").TerrainGenerator;

/// Owns global state
pub const Engine = struct {
    allocator: std.mem.Allocator,
    renderer: Renderer,
    platform: SdlPlatform,
    graphics: SdlGraphics,
    tile_pool: TilePool,
    atlas: Atlas,
    world: World,
    rasterizer: Rasterizer,
    terrain_generator: *TerrainGenerator,
    player: Player,
    chunk_worker: *ChunkWorker,
    chunk_manager: ChunkManager,
    text: Text,
    text2: Text,

    pub fn init(allocator: std.mem.Allocator, conf: EngineConfig) !Engine {
        const text = try Text.init("font.bdf");
        const text2 = try Text.init("font2.bdf");
        const tile_pool = try TilePool.init(allocator, conf.framebuffer_config);
        const platform = SdlPlatform.init();
        const graphics = try SdlGraphics.init(conf.framebuffer_config);
        const atlas = try Atlas.init(allocator, conf.atlas_config);
        const world = World.init(allocator);
        const rasterizer = try Rasterizer.init(allocator, tile_pool.count);

        const terrain_generator = try allocator.create(TerrainGenerator);
        terrain_generator.* = TerrainGenerator.init(conf.world_config);

        const chunk_worker = try allocator.create(ChunkWorker);
        chunk_worker.* = try ChunkWorker.init(allocator, 320_000, terrain_generator);
        try chunk_worker.start();

        const player = Player.init(
            conf.player_config,
            conf.camera_config,
            conf.framebuffer_config.width,
            conf.framebuffer_config.height,
        );
        const renderer = try Renderer.init(
            allocator,
            conf.framebuffer_config,
            conf.camera_config.view_distance,
        );

        // TODO: Remove magic numbers
        const chunk_manager = try ChunkManager.init(allocator, 800, 1_000, -192.0, 320.0);

        return Engine{
            .allocator = allocator,
            .player = player,
            .renderer = renderer,
            .platform = platform,
            .graphics = graphics,
            .tile_pool = tile_pool,
            .atlas = atlas,
            .world = world,
            .rasterizer = rasterizer,
            .terrain_generator = terrain_generator,
            .chunk_worker = chunk_worker,
            .chunk_manager = chunk_manager,
            .text = text,
            .text2 = text2,
        };
    }

    pub fn deinit(self: *Engine) void {
        _ = self;
    }

    pub fn beginFrame(self: *Engine, sky_rows: []u32) !FrameContext {
        self.renderer.beginFrame();
        const dt = self.platform.begin_frame();
        const framebuffer = try self.graphics.begin_frame();
        framebuffer.clearGradient(sky_rows);

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
