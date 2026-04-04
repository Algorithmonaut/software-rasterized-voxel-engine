const std = @import("std");

const Block = @import("Block.zig");
const BlockId = Block.BlockId;

const WorldConfig = @import("../EngineConfig.zig").EngineConfig.WorldConfig;

//// DETERMINISTIC HASHING ////

fn hash2(x: i32, y: i32, seed: u32) u32 {
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

fn hash2Signed(x: i32, y: i32, seed: u32) f32 {
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

fn valueNoise2(x: f32, y: f32, seed: u32) f32 {
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

fn fbm2(x: f32, y: f32, octaves: u32, gain: f32, lacunarity: f32, seed: u32) f32 {
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
        };
    }

    pub fn deinit(self: TerrainGenerator) void {
        _ = self;
    }

    fn terrainHeight(self: TerrainGenerator, world_x: i32, world_z: i32) i32 {
        const nx = @as(f32, @floatFromInt(world_x)) * self.scale;
        const nz = @as(f32, @floatFromInt(world_z)) * self.scale;

        // Replace by a valid seed
        const h = fbm2(nx, nz, self.octaves, self.gain, self.lacunarity, self.seed);
        const base_height: f32 = 32.0;
        const amplitude: f32 = 24.0;

        return @intFromFloat(base_height + h * amplitude);
    }

    pub fn fillChunkVoxels(
        self: TerrainGenerator,
        voxels: []BlockId,
        chunk_coord: @Vector(3, i32),
        size: usize,
    ) void {
        const chunk_size_i: i32 = @intCast(size);

        for (0..size) |z| {
            for (0..size) |x| {
                const world_x = chunk_coord[0] * chunk_size_i + @as(i32, @intCast(x));
                const world_z = chunk_coord[2] * chunk_size_i + @as(i32, @intCast(z));
                const h = self.terrainHeight(world_x, world_z);

                for (0..size) |y| {
                    const world_y = chunk_coord[1] * chunk_size_i + @as(i32, @intCast(y));
                    const idx = x + y * size + z * size * size;

                    if (world_y > h) {
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
    }
};
