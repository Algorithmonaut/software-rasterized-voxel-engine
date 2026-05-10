const std = @import("std");
const types = @import("../types.zig");
const helpers = @import("../helpers.zig");
const constants = @import("../constants.zig");

const Block = types.Block;
const BlockId = types.BlockId;
const ChunkCoord = types.ChunkCoord;
const ChunkSliceCoord = types.ChunkSliceCoord;
const BitfieldViews = types.BitfieldViews;
const WorldConfig = @import("../EngineConfig.zig").EngineConfig.WorldConfig;

const CHUNK_SIZE = constants.CHUNK_SIZE;

//// TUNING ////

const SEA_LEVEL: i32 = 0;

const BEACH_HEIGHT: i32 = 2;
const BEACH_DEPTH: i32 = 4;

const DIRT_DEPTH: i32 = 4;
const SAND_DEPTH: i32 = 5;

const TREE_CANOPY_RADIUS: i32 = 2;

const COAL_CHANCE: u32 = 211;
const IRON_CHANCE: u32 = 337;

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

inline fn hash3(x: i32, y: i32, z: i32, seed: u32) u32 {
    var h = hash2(x, z, seed);

    h ^= @as(u32, @bitCast(y)) *% 0xc2b2ae35;
    h = std.math.rotl(u32, h, 13);
    h *%= 0x27d4eb2d;

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
    return t * 2.0 - 1.0;
}

//// VALUE NOISE ////

/// Classic Perlin quintic fade.
inline fn fadeQuintic(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

inline fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

inline fn saturate(v: f32) f32 {
    return std.math.clamp(v, 0.0, 1.0);
}

inline fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = saturate((x - edge0) / (edge1 - edge0));
    return t * t * (3.0 - 2.0 * t);
}

inline fn safeScale(scale: f32) f32 {
    const s = if (scale < 0.0) -scale else scale;
    return if (s < 0.000001) 0.000001 else s;
}

inline fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
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
    if (octaves == 0) return 0.0;

    var sum: f32 = 0.0;
    var amp: f32 = 1.0;
    var freq: f32 = 1.0;
    var norm: f32 = 0.0;

    var i: u32 = 0;
    while (i < octaves) : (i += 1) {
        sum += valueNoise2(x * freq, y * freq, seed +% (i *% 1013)) * amp;
        norm += amp;
        amp *= gain;
        freq *= lacunarity;
    }

    return sum / norm;
}

inline fn ridgedFbm2(x: f32, y: f32, octaves: u32, gain: f32, lacunarity: f32, seed: u32) f32 {
    if (octaves == 0) return 0.0;

    var sum: f32 = 0.0;
    var amp: f32 = 1.0;
    var freq: f32 = 1.0;
    var norm: f32 = 0.0;

    var i: u32 = 0;
    while (i < octaves) : (i += 1) {
        const n = valueNoise2(x * freq, y * freq, seed +% (i *% 1619));
        const r = 1.0 - @abs(n);

        sum += r * r * amp;
        norm += amp;

        amp *= gain;
        freq *= lacunarity;
    }

    return sum / norm;
}

//// BIOMES ////

const Biome = enum {
    plains,
    forest,
    desert,
    beach,
    frozen_shore,
    tundra,
    highlands,
    rocky_mountains,
    snowy_mountains,
};

const Climate = struct {
    temperature: f32,
    moisture: f32,
};

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
    chunk_min_y: i32,
    chunk_max_y: i32,
    chunk_y_count: usize,

    pub fn init(conf: WorldConfig) TerrainGenerator {
        const chunk_size_f: f32 = @floatFromInt(CHUNK_SIZE);
        const min_world_y_f: f32 = @floatFromInt(conf.min_world_y);
        const max_world_y_f: f32 = @floatFromInt(conf.max_world_y);

        const chunk_min_y: i32 = @intFromFloat(@floor(min_world_y_f / chunk_size_f));
        const chunk_max_y: i32 = @intFromFloat(@ceil(max_world_y_f / chunk_size_f));

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
            .chunk_min_y = chunk_min_y,
            .chunk_max_y = chunk_max_y,
            .chunk_y_count = @intCast(chunk_max_y - chunk_min_y),
        };
    }

    pub fn deinit(self: TerrainGenerator) void {
        _ = self;
    }

    inline fn seaLevel(self: TerrainGenerator) i32 {
        return std.math.clamp(SEA_LEVEL, self.min_world_y, self.max_world_y);
    }

    inline fn climateAt(self: TerrainGenerator, world_x: i32, world_z: i32, height: i32) Climate {
        const scale = safeScale(self.scale);

        const x = @as(f32, @floatFromInt(world_x));
        const z = @as(f32, @floatFromInt(world_z));

        const nx = x * scale;
        const nz = z * scale;

        var temperature = fbm2(
            nx * 0.18 + 37.2,
            nz * 0.18 - 91.7,
            4,
            0.55,
            2.0,
            self.seed +% 0x9e3779b9,
        ) * 0.5 + 0.5;

        var moisture = fbm2(
            nx * 0.22 - 15.5,
            nz * 0.22 + 44.1,
            4,
            0.55,
            2.0,
            self.seed +% 0x85ebca6b,
        ) * 0.5 + 0.5;

        const elevation = @as(f32, @floatFromInt(height - self.seaLevel()));

        // Higher terrain is colder. Low terrain trends slightly wetter.
        temperature -= elevation * 0.0065;
        if (elevation <= 4.0) moisture += 0.10;

        return .{
            .temperature = saturate(temperature),
            .moisture = saturate(moisture),
        };
    }

    inline fn biomeAt(self: TerrainGenerator, world_x: i32, world_z: i32, height: i32) Biome {
        const sea = self.seaLevel();
        const above_sea = height - sea;
        const climate = self.climateAt(world_x, world_z, height);

        if (above_sea <= BEACH_HEIGHT and above_sea >= -BEACH_DEPTH) {
            if (climate.temperature < 0.24) return .frozen_shore;
            return .beach;
        }

        if (above_sea >= 54) {
            if (climate.temperature < 0.52) return .snowy_mountains;
            return .rocky_mountains;
        }

        if (above_sea >= 34) {
            if (climate.temperature < 0.35) return .snowy_mountains;
            return .rocky_mountains;
        }

        if (above_sea >= 22) {
            if (climate.temperature < 0.30) return .tundra;
            return .highlands;
        }

        if (climate.temperature < 0.22) return .tundra;

        if (climate.temperature > 0.68 and climate.moisture < 0.42) {
            return .desert;
        }

        if (climate.moisture > 0.57) {
            return .forest;
        }

        return .plains;
    }

    inline fn terrainHeight(self: TerrainGenerator, world_x: i32, world_z: i32) i32 {
        const scale = safeScale(self.scale);
        const mountain_scale = safeScale(self.mountain_scale);

        const x = @as(f32, @floatFromInt(world_x));
        const z = @as(f32, @floatFromInt(world_z));

        const nx = x * scale;
        const nz = z * scale;

        // Domain warp keeps terrain from looking grid-aligned.
        const warp_x = fbm2(
            nx * 0.35 + 13.7,
            nz * 0.35 - 8.1,
            3,
            0.50,
            2.0,
            self.seed +% 0x1f123bb5,
        ) * 0.75;

        const warp_z = fbm2(
            nx * 0.35 - 53.2,
            nz * 0.35 + 22.9,
            3,
            0.50,
            2.0,
            self.seed +% 0x6ac690c5,
        ) * 0.75;

        const wx = nx + warp_x;
        const wz = nz + warp_z;

        // Large-scale landmass mask.
        const continent = fbm2(
            wx * 0.28,
            wz * 0.28,
            5,
            0.56,
            2.0,
            self.seed +% 0x243f6a88,
        ) * 0.5 + 0.5;

        const land = smoothstep(0.18, 0.88, continent);

        // Rolling base terrain.
        const base = lerp(-10.0, 18.0, land);

        const lowlands = fbm2(
            wx * 1.10,
            wz * 1.10,
            self.octaves,
            self.gain,
            self.lacunarity,
            self.seed,
        ) * 10.0;

        const hill_mask = smoothstep(0.35, 0.80, continent);

        const hills = fbm2(
            wx * 2.15 + 101.0,
            wz * 2.15 - 41.0,
            4,
            0.52,
            2.05,
            self.seed +% 0xb7e15162,
        ) * 11.0 * hill_mask;

        // Mountains are masked to appear more inland and are ridged.
        const mountain_region = fbm2(
            x * mountain_scale * 0.42 + 5.0,
            z * mountain_scale * 0.42 - 17.0,
            self.mountain_octaves,
            self.mountain_gain,
            self.mountain_lacunarity,
            self.mountain_seed,
        ) * 0.5 + 0.5;

        const mountain_mask =
            smoothstep(0.52, 0.82, mountain_region) *
            smoothstep(0.34, 0.68, continent);

        const ridges = ridgedFbm2(
            x * mountain_scale,
            z * mountain_scale,
            self.mountain_octaves,
            self.mountain_gain,
            self.mountain_lacunarity,
            self.mountain_seed +% 0x94d049bb,
        );

        const mountain_height = (ridges * ridges * 56.0 + ridges * 10.0) * mountain_mask;

        const detail = fbm2(
            wx * 5.20 - 2.0,
            wz * 5.20 + 9.0,
            3,
            0.45,
            2.2,
            self.seed +% 0x3c6ef372,
        ) * 2.25;

        const height_f = base + lowlands + hills + mountain_height + detail;

        return @intFromFloat(@round(height_f));
    }

    inline fn surfaceSlope(self: TerrainGenerator, world_x: i32, world_z: i32, height: i32) i32 {
        const h1 = self.terrainHeight(world_x + 1, world_z);
        const h2 = self.terrainHeight(world_x - 1, world_z);
        const h3 = self.terrainHeight(world_x, world_z + 1);
        const h4 = self.terrainHeight(world_x, world_z - 1);

        var slope = absI32(height - h1);
        slope = @max(slope, absI32(height - h2));
        slope = @max(slope, absI32(height - h3));
        slope = @max(slope, absI32(height - h4));

        return slope;
    }

    inline fn surfaceBlockForBiome(
        self: TerrainGenerator,
        biome: Biome,
        height: i32,
        slope: i32,
    ) BlockId {
        const sea = self.seaLevel();
        const above_sea = height - sea;

        return switch (biome) {
            .beach => .sand,
            .frozen_shore => .ice,
            .desert => .sand,
            .tundra => .snow,
            .snowy_mountains => .snow,

            .rocky_mountains => if (slope >= 3 or above_sea >= 42) .stone else .grass,
            .highlands => if (slope >= 4) .stone else .grass,

            .forest, .plains => if (slope >= 5) .stone else .grass,
        };
    }

    inline fn subsurfaceBlockForBiome(
        biome: Biome,
        depth: i32,
        slope: i32,
    ) BlockId {
        return switch (biome) {
            .beach => if (depth <= SAND_DEPTH) .sand else .stone,
            .frozen_shore => if (depth == 1) .sand else .stone,
            .desert => if (depth <= SAND_DEPTH) .sand else .stone,

            .rocky_mountains, .snowy_mountains => if (slope >= 3 or depth > 2) .stone else .dirt,

            .tundra, .highlands, .forest, .plains => if (depth <= DIRT_DEPTH) .dirt else .stone,
        };
    }

    inline fn deepStoneBlock(self: TerrainGenerator, world_x: i32, y: i32, world_z: i32) BlockId {
        const deep_threshold = @min(self.seaLevel() - 32, self.min_world_y + 24);
        const base: BlockId = if (y <= deep_threshold) .deepslate else .stone;

        const h = hash3(world_x, y, world_z, self.seed +% 0x0ddba11);

        if (base == .stone or base == .deepslate) {
            if (y <= self.seaLevel() + 42 and h % COAL_CHANCE == 0) {
                return .coal_ore;
            }

            if (y <= self.seaLevel() + 18 and ((h >> 8) % IRON_CHANCE) == 0) {
                return .iron_ore;
            }
        }

        return base;
    }

    inline fn blockForTerrain(
        self: TerrainGenerator,
        world_x: i32,
        y: i32,
        world_z: i32,
        height: i32,
        biome: Biome,
        slope: i32,
    ) Block {
        const depth = height - y;

        const id: BlockId = if (depth == 0)
            self.surfaceBlockForBiome(biome, height, slope)
        else if (depth <= @max(DIRT_DEPTH, SAND_DEPTH))
            subsurfaceBlockForBiome(biome, depth, slope)
        else
            self.deepStoneBlock(world_x, y, world_z);

        const light: u4 = if (depth == 0) 15 else 0;

        return .{ .id = id, .light_level = light };
    }

    inline fn generateChunkBitfieldViews(voxels: []Block, bitfield_views: *BitfieldViews) void {
        const size = CHUNK_SIZE;

        for (0..size) |x_u| {
            const x: u5 = @intCast(x_u);
            const mx: u32 = @as(u32, 1) << x;

            for (0..size) |y_u| {
                const y: u5 = @intCast(y_u);
                const my: u32 = @as(u32, 1) << y;

                for (0..size) |z_u| {
                    const z: u5 = @intCast(z_u);
                    const mz: u32 = @as(u32, 1) << z;

                    const idx = helpers.voxelIndex(size, x_u, y_u, z_u);
                    if (voxels[idx].id == .air) continue;

                    bitfield_views.solid_x[y_u][z_u] |= mx;
                    bitfield_views.solid_y[x_u][z_u] |= my;
                    bitfield_views.solid_z[x_u][y_u] |= mz;
                }
            }
        }
    }

    inline fn setBlockInResults(
        self: *const TerrainGenerator,
        results: []GenerationResult,
        coord: ChunkSliceCoord,
        world_x: i32,
        world_y: i32,
        world_z: i32,
        id: BlockId,
        only_if_air: bool,
    ) void {
        if (world_y < self.min_world_y or world_y > self.max_world_y) return;

        const size = CHUNK_SIZE;
        const size_i32: i32 = @intCast(size);

        const chunk_origin_x = coord[0] * size_i32;
        const chunk_origin_z = coord[1] * size_i32;

        const local_x_i32 = world_x - chunk_origin_x;
        const local_z_i32 = world_z - chunk_origin_z;

        if (local_x_i32 < 0 or local_x_i32 >= size_i32) return;
        if (local_z_i32 < 0 or local_z_i32 >= size_i32) return;

        const chunk_y = @divFloor(world_y, size_i32);
        const chunk_index_i32 = chunk_y - self.chunk_min_y;

        if (chunk_index_i32 < 0) return;
        if (chunk_index_i32 >= @as(i32, @intCast(self.chunk_y_count))) return;

        const chunk_index: usize = @intCast(chunk_index_i32);
        const local_x: usize = @intCast(local_x_i32);
        const local_y: usize = @intCast(@mod(world_y, size_i32));
        const local_z: usize = @intCast(local_z_i32);

        const idx = helpers.voxelIndex(size, local_x, local_y, local_z);

        if (only_if_air and results[chunk_index].voxels[idx].id != .air) return;

        results[chunk_index].voxels[idx] = .{ .id = id, .light_level = 15 };
    }

    inline fn supportsTrees(self: TerrainGenerator, biome: Biome, height: i32, slope: i32) bool {
        const above_sea = height - self.seaLevel();

        if (above_sea <= BEACH_HEIGHT + 1) return false;
        if (slope > 2) return false;

        return switch (biome) {
            .forest, .plains => true,
            else => false,
        };
    }

    inline fn isTreeOrigin(
        self: TerrainGenerator,
        world_x: i32,
        world_z: i32,
        height: i32,
        biome: Biome,
        slope: i32,
    ) bool {
        if (!self.supportsTrees(biome, height, slope)) return false;

        const spacing: i32 = switch (biome) {
            .forest => 5,
            .plains => 9,
            else => return false,
        };

        const cell_x = @divFloor(world_x, spacing);
        const cell_z = @divFloor(world_z, spacing);

        const r = hash2(cell_x, cell_z, self.seed +% 0x745a17);
        const spacing_u: u32 = @intCast(spacing);

        const offset_x: i32 = @intCast(r % spacing_u);
        const offset_z: i32 = @intCast((r >> 8) % spacing_u);

        const origin_x = cell_x * spacing + offset_x;
        const origin_z = cell_z * spacing + offset_z;

        if (world_x != origin_x or world_z != origin_z) return false;

        const chance: u32 = switch (biome) {
            .forest => 78,
            .plains => 18,
            else => 0,
        };

        return ((r >> 16) % 100) < chance;
    }

    fn placeOakTree(
        self: *const TerrainGenerator,
        results: []GenerationResult,
        coord: ChunkSliceCoord,
        root_x: i32,
        ground_y: i32,
        root_z: i32,
    ) void {
        const r = hash2(root_x, root_z, self.seed +% 0xa511e9b3);
        const trunk_height: i32 = 4 + @as(i32, @intCast(r % 4));

        var trunk_y: i32 = ground_y + 1;
        while (trunk_y <= ground_y + trunk_height) : (trunk_y += 1) {
            self.setBlockInResults(
                results,
                coord,
                root_x,
                trunk_y,
                root_z,
                .oak_log,
                false,
            );
        }

        const canopy_center_y = ground_y + trunk_height;

        var dy: i32 = -2;
        while (dy <= 2) : (dy += 1) {
            const radius: i32 = if (dy <= 0) TREE_CANOPY_RADIUS else 1;

            var dz: i32 = -radius;
            while (dz <= radius) : (dz += 1) {
                var dx: i32 = -radius;
                while (dx <= radius) : (dx += 1) {
                    const dist = absI32(dx) + absI32(dz);

                    if (dy == 2 and dist > 1) continue;
                    if (dy <= 0 and dist > 3) continue;

                    const leaf_x = root_x + dx;
                    const leaf_y = canopy_center_y + dy;
                    const leaf_z = root_z + dz;

                    const corner = absI32(dx) == radius and absI32(dz) == radius;
                    const leaf_hash = hash3(leaf_x, leaf_y, leaf_z, self.seed +% 0x632be59b);

                    if (corner and (leaf_hash & 1) == 0) continue;

                    self.setBlockInResults(
                        results,
                        coord,
                        leaf_x,
                        leaf_y,
                        leaf_z,
                        .oak_leaves,
                        true,
                    );
                }
            }
        }
    }

    fn generateTrees(
        self: *const TerrainGenerator,
        results: []GenerationResult,
        coord: ChunkSliceCoord,
    ) void {
        const size_i32: i32 = @intCast(CHUNK_SIZE);
        const margin = TREE_CANOPY_RADIUS;

        var local_z: i32 = -margin;
        while (local_z < size_i32 + margin) : (local_z += 1) {
            var local_x: i32 = -margin;
            while (local_x < size_i32 + margin) : (local_x += 1) {
                const world_x = coord[0] * size_i32 + local_x;
                const world_z = coord[1] * size_i32 + local_z;

                const h_unclamped = self.terrainHeight(world_x, world_z);
                const height = std.math.clamp(h_unclamped, self.min_world_y, self.max_world_y);

                const slope = self.surfaceSlope(world_x, world_z, height);
                const biome = self.biomeAt(world_x, world_z, height);

                if (!self.isTreeOrigin(world_x, world_z, height, biome, slope)) continue;

                self.placeOakTree(results, coord, world_x, height, world_z);
            }
        }
    }

    pub fn fillChunkSliceVoxels(
        self: *const TerrainGenerator,
        allocator: std.mem.Allocator,
        coord: ChunkSliceCoord,
    ) ![]GenerationResult {
        const size = CHUNK_SIZE;
        const size_i32: i32 = @intCast(size);

        const results = try allocator.alloc(GenerationResult, self.chunk_y_count);
        errdefer allocator.free(results);

        for (0..self.chunk_y_count) |i| {
            const chunk_y = self.chunk_min_y + @as(i32, @intCast(i));

            const voxels = try allocator.alloc(Block, CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE);
            errdefer allocator.free(voxels);

            const bitfield_views = try allocator.create(BitfieldViews);
            errdefer allocator.destroy(bitfield_views);

            @memset(voxels, .{ .id = .air, .light_level = 15 });
            bitfield_views.* = std.mem.zeroes(BitfieldViews);

            results[i] = .{
                .coord = .{ coord[0], chunk_y, coord[1] },
                .voxels = voxels,
                .bitfield_views = bitfield_views,
            };
        }

        for (0..size) |z| {
            for (0..size) |x| {
                const world_x = coord[0] * size_i32 + @as(i32, @intCast(x));
                const world_z = coord[1] * size_i32 + @as(i32, @intCast(z));

                const h_unclamped = self.terrainHeight(world_x, world_z);
                const height = std.math.clamp(h_unclamped, self.min_world_y, self.max_world_y);

                const slope = self.surfaceSlope(world_x, world_z, height);
                const biome = self.biomeAt(world_x, world_z, height);

                var y: i32 = self.min_world_y;
                while (y <= height) : (y += 1) {
                    const chunk_y = @divFloor(y, size_i32);
                    const chunk_index: usize = @intCast(chunk_y - self.chunk_min_y);
                    const local_y: usize = @intCast(@mod(y, size_i32));
                    const idx = helpers.voxelIndex(size, x, local_y, z);

                    results[chunk_index].voxels[idx] = self.blockForTerrain(
                        world_x,
                        y,
                        world_z,
                        height,
                        biome,
                        slope,
                    );
                }
            }
        }

        self.generateTrees(results, coord);

        for (results) |result| {
            generateChunkBitfieldViews(result.voxels, result.bitfield_views);
        }

        return results;
    }
};

pub const GenerationResult = struct {
    coord: ChunkCoord,
    voxels: []Block,
    bitfield_views: *BitfieldViews,
};
