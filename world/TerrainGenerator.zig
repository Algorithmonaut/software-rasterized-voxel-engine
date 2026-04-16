const std = @import("std");

const Block = @import("Block.zig");
const BlockId = Block.BlockId;

const WorldConfig = @import("../EngineConfig.zig").EngineConfig.WorldConfig;

const ChunkCoord = @import("../math/types.zig").ChunkCoord;

const BitfieldViews = @import("Chunk.zig").BitfieldViews;

const CHUNK_SIZE = @import("Chunk.zig").CHUNK_SIZE;

//// DETERMINISTIC HASHING ////

inline fn hash2(x: i32, y: i32, seed: u32) u32 {
    var h: u32 = seed;

    h ^= @as(u32, @bitCast(x)) *% 0x27d4eb2d;
    h = std.math.rotl(u32, h, 15);

    h ^= @as(u32, @bitCast(y)) *% 0x85ebca6b;

    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    h *%= 0x846ca68b;
    h ^= h >> 16;

    return h;
}

inline fn hash2Signed(x: i32, y: i32, seed: u32) f32 {
    const h = hash2(x, y, seed);
    const t = @as(f32, @floatFromInt(h)) / 4294967295.0;
    return t * 2.0 - 1.0; // [-1, 1]
}

//// VALUE NOISE ////

/// Classic perlin quintic fade
inline fn fadeQuintic(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

inline fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

inline fn valueNoise2(x: f32, y: f32, seed: u32) f32 {
    const x0: i32 = @intFromFloat(@floor(x));
    const y0: i32 = @intFromFloat(@floor(y));
    const x1 = x0 + 1;
    const y1 = y0 + 1;

    const tx = x - @as(f32, @floatFromInt(x0));
    const ty = y - @as(f32, @floatFromInt(y0));

    const sx = fadeQuintic(tx);
    const sy = fadeQuintic(ty);

    const v00 = hash2Signed(x0, y0, seed);
    const v01 = hash2Signed(x0, y1, seed);
    const v10 = hash2Signed(x1, y0, seed);
    const v11 = hash2Signed(x1, y1, seed);

    const ix0 = lerp(v00, v10, sx);
    const ix1 = lerp(v01, v11, sx);

    return lerp(ix0, ix1, sy);
}

inline fn fbm2(x: f32, y: f32, octaves: u32, gain: f32, lacunarity: f32, seed: u32) f32 {
    var sum: f32 = 0.0;
    var amp: f32 = 1.0;
    var freq: f32 = 1.0;
    var norm: f32 = 0.0;

    var i: u32 = 0;
    while (i < octaves) : (i += 1) {
        sum += valueNoise2(x * freq, y * freq, seed + i * 1013) * amp;
        norm += amp;
        amp *= gain;
        freq *= lacunarity;
    }

    return sum / norm;
}

//// TERRAIN GENERATION ////

pub const TerrainGenerator = struct {
    seed: u32,
    /// Number of noise layouts combined together
    octaves: u32,
    /// How much the frequency increase between each octaves
    lacunarity: f32,
    /// Multiplier for how much each octave contributes to the final result
    gain: f32,
    /// Smaller = smoother terrain
    scale: f32,

    mountain_seed: u32,
    mountain_octaves: u32,
    mountain_lacunarity: f32,
    mountain_gain: f32,
    mountain_scale: f32,

    min_world_y: i32,
    max_world_y: i32,

    pub fn init(conf: WorldConfig) TerrainGenerator {
        return .{
            .seed = conf.seed,
            .octaves = conf.octaves,
            .lacunarity = conf.lacunarity,
            .gain = conf.gain,
            .scale = conf.scale,
            .mountain_seed = conf.mountain_seed,
            .mountain_octaves = conf.mountain_octaves,
            .mountain_lacunarity = conf.mountain_lacunarity,
            .mountain_gain = conf.mountain_gain,
            .mountain_scale = conf.mountain_scale,
            .min_world_y = conf.min_world_y,
            .max_world_y = conf.max_world_y - 1,
        };
    }

    pub fn deinit(self: TerrainGenerator) void {
        _ = self;
    }

    inline fn terrainHeight(self: TerrainGenerator, world_x: i32, world_z: i32) i32 {
        const nx = @as(f32, @floatFromInt(world_x)) * self.scale;
        const nz = @as(f32, @floatFromInt(world_z)) * self.scale;

        // Replace by a valid seed
        const h = fbm2(nx, nz, self.octaves, self.gain, self.lacunarity, self.seed);
        // TODO: Move to conf
        const base_height: f32 = 32.0;
        const amplitude: f32 = 24.0;

        return @intFromFloat(base_height + h * amplitude);
    }

    inline fn generateChunkBitfieldViews(voxels: []BlockId, bitfield_views: *BitfieldViews) void {
        for (0..CHUNK_SIZE) |x_u| {
            const x: u5 = @intCast(x_u);
            const mx: u32 = @as(u32, 1) << x;

            for (0..CHUNK_SIZE) |y_u| {
                const y: u5 = @intCast(y_u);
                const my: u32 = @as(u32, 1) << y;

                for (0..CHUNK_SIZE) |z_u| {
                    const z: u5 = @intCast(z_u);
                    const mz: u32 = @as(u32, 1) << z;

                    const idx = x_u + y_u * CHUNK_SIZE + z_u * CHUNK_SIZE * CHUNK_SIZE;
                    if (voxels[idx] == .air) continue;

                    bitfield_views.solid_x[y_u][z_u] |= mx;
                    bitfield_views.solid_y[x_u][z_u] |= my;
                    bitfield_views.solid_z[x_u][y_u] |= mz;
                }
            }
        }
    }

    pub fn fillChunkVoxels(
        self: *TerrainGenerator,
        allocator: std.mem.Allocator,
        job: GenerationJob,
    ) !GenerationResult {
        const size = CHUNK_SIZE;

        const voxels = try allocator.alloc(BlockId, size * size * size);

        const bitfield_views = try allocator.create(BitfieldViews);
        bitfield_views.* = std.mem.zeroInit(BitfieldViews, .{});

        const chunk_min_y = job.coord[1] * size;
        const chunk_max_y = chunk_min_y + size;

        if (chunk_max_y <= self.min_world_y or chunk_min_y > self.max_world_y) {
            @memset(voxels, .air);

            return .{
                .coord = job.coord,
                .voxels = voxels,
                .bitfield_views = bitfield_views,
            };
        }

        for (0..size) |z| {
            for (0..size) |x| {
                const world_x = job.coord[0] * size + @as(i32, @intCast(x));
                const world_z = job.coord[2] * size + @as(i32, @intCast(z));
                const h_unclamped = self.terrainHeight(world_x, world_z);
                const h = std.math.clamp(h_unclamped, self.min_world_y, self.max_world_y);

                for (0..size) |y| {
                    const world_y = job.coord[1] * size + @as(i32, @intCast(y));
                    const idx = x + y * size + z * size * size;

                    if (world_y < self.min_world_y) {
                        voxels[idx] = .air;
                    } else if (world_y >= self.max_world_y) {
                        voxels[idx] = .air;
                    } else if (world_y > h) {
                        voxels[idx] = .air;
                    } else if (world_y == h) {
                        voxels[idx] = .grass;
                    } else if (world_y >= h - 3) {
                        voxels[idx] = .dirt;
                    } else {
                        voxels[idx] = .stone;
                    }
                }
            }
        }

        generateChunkBitfieldViews(voxels, bitfield_views);

        return .{
            .coord = job.coord,
            .voxels = voxels,
            .bitfield_views = bitfield_views,
        };
    }
};

pub const GenerationJob = struct {
    coord: ChunkCoord,
};

pub const GenerationResult = struct {
    coord: ChunkCoord,
    voxels: []BlockId,
    bitfield_views: *BitfieldViews,
};
