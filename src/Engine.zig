const std = @import("std");
const types = @import("types.zig");

const F3 = types.F3;
const FrameContext = types.FrameContext;
const TilePool = @import("tile.zig").TilePool;
const World = @import("world/World.zig").World;
const Player = @import("game/Player.zig").Player;
const EngineConfig = @import("EngineConfig.zig").EngineConfig;
const Rasterizer = @import("renderer/Rasterizer.zig").Rasterizer;
const ChunkWorker = @import("world/ChunkWorker.zig").ChunkWorker;
const SdlPlatform = @import("platform/SdlPlatform.zig").SdlPlatform;
const SdlGraphics = @import("platform/SdlGraphics.zig").SdlGraphics;
const ChunkManager = @import("world/ChunkManager.zig").ChunkManager;
const PrimitiveBuilder = @import("PrimitiveBuilder.zig").PrimitiveBuilder;
const TerrainGenerator = @import("world/TerrainGenerator.zig").TerrainGenerator;

/// Owns global state
pub const Engine = struct {
    allocator: std.mem.Allocator,
    primitive_builder: PrimitiveBuilder,
    platform: SdlPlatform,
    graphics: SdlGraphics,
    tile_pool: TilePool,
    world: World,
    rasterizer: Rasterizer,
    terrain_generator: *TerrainGenerator,
    player: Player,
    chunk_worker: *ChunkWorker,
    chunk_manager: ChunkManager,

    pub fn init(allocator: std.mem.Allocator, conf: EngineConfig, io: std.Io) !Engine {
        const tile_pool = try TilePool.init(allocator, conf.framebuffer_config);
        const platform = SdlPlatform.init();
        const graphics = try SdlGraphics.init(conf.framebuffer_config);
        const world = World.init(allocator);
        const rasterizer = try Rasterizer.init(allocator, tile_pool.count);

        const terrain_generator = try allocator.create(TerrainGenerator);
        terrain_generator.* = TerrainGenerator.init(conf.world_config);

        const chunk_worker = try allocator.create(ChunkWorker);
        chunk_worker.* = try ChunkWorker.init(allocator, 320_000, terrain_generator, io);
        try chunk_worker.start();

        const player = Player.init(
            conf.player_config,
            conf.camera_config,
            conf.framebuffer_config.width,
            conf.framebuffer_config.height,
        );

        const primitive_builder = try PrimitiveBuilder.init(allocator, conf.framebuffer_config);

        // TODO: Remove magic numbers
        const chunk_manager = try ChunkManager.init(allocator, 800, 1_000, -192.0, 320.0);

        return Engine{
            .allocator = allocator,
            .player = player,
            .primitive_builder = primitive_builder,
            .platform = platform,
            .graphics = graphics,
            .tile_pool = tile_pool,
            .world = world,
            .rasterizer = rasterizer,
            .terrain_generator = terrain_generator,
            .chunk_worker = chunk_worker,
            .chunk_manager = chunk_manager,
        };
    }

    pub fn deinit(self: *Engine) void {
        _ = self;
    }

    pub fn beginFrame(self: *Engine, sky_rows: []u32) !FrameContext {
        const dt = self.platform.beginFrame();
        const framebuffer = try self.graphics.beginFrame();
        framebuffer.clearGradient(sky_rows);

        return .{
            .dt = dt,
            .framebuffer = framebuffer,
        };
    }

    pub fn endFrame(self: *Engine, frame: *FrameContext) void {
        self.graphics.endFrame();
        self.graphics.present();

        self.platform.fpsCounterUpdate();

        _ = frame;
    }
};
