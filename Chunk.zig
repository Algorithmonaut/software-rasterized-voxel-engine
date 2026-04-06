const std = @import("std");
const Float = @import("math/types.zig").Float;
const BlockType = @import("Atlas.zig").BlockTypes;

const ChunkCoord = @import("math/types.zig").ChunkCoord;
const World = @import("World.zig").World;

const Block = @import("world/Block.zig");
const Quad = Block.Quad;
const BlockId = Block.BlockId;
const TerrainGenerator = @import("world/TerrainGenerator.zig").TerrainGenerator;

pub const CHUNK_SIZE = 32;
const LOD1_CHUNK_SIZE = CHUNK_SIZE / 2;
const LOD2_CHUNK_SIZE = LOD1_CHUNK_SIZE / 2;
const LOD3_CHUNK_SIZE = LOD2_CHUNK_SIZE / 2;
const LOD4_CHUNK_SIZE = LOD3_CHUNK_SIZE / 2;

//// VOXEL DATA ////////////////////////////////////////////////////////////////

const ChunkLods = struct {
    lod0: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]BlockId, // 32^3
    lod1: [LOD1_CHUNK_SIZE * LOD1_CHUNK_SIZE * LOD1_CHUNK_SIZE]BlockId, // 16 ^ 3
    lod2: [LOD2_CHUNK_SIZE * LOD2_CHUNK_SIZE * LOD2_CHUNK_SIZE]BlockId, // 8 ^ 3
    lod3: [LOD3_CHUNK_SIZE * LOD3_CHUNK_SIZE * LOD3_CHUNK_SIZE]BlockId, // 4 ^ 3
    lod4: [LOD4_CHUNK_SIZE * LOD4_CHUNK_SIZE * LOD4_CHUNK_SIZE]BlockId, // 2 ^ 3

};

inline fn voxelIndex(size: usize, x: usize, y: usize, z: usize) usize {
    return x + y * size + z * size * size;
}

fn chooseBlockFrom2x2x2(
    src: []const BlockId,
    src_size: usize,
    bx: usize,
    by: usize,
    bz: usize,
) BlockId {
    var solid_count: usize = 0;

    var best_id: BlockId = .unknown;
    var best_count: usize = 0;

    var counts: [256]u8 = [_]u8{0} ** 256;

    for (0..2) |dz| {
        for (0..2) |dy| {
            for (0..2) |dx| {
                const id = src[voxelIndex(src_size, bx + dx, by + dy, bz + dz)];
                if (id == .air) continue;

                solid_count += 1;

                const idx: usize = @intCast(@intFromEnum(id));
                counts[idx] += 1;

                if (counts[idx] > best_count) {
                    best_count = counts[idx];
                    best_id = id;
                }
            }
        }
    }

    if (solid_count >= 4) return best_id;
    return .air;
}

fn buildLod(
    src: []const BlockId,
    src_size: usize,
    dst: []BlockId,
) void {
    std.debug.assert(src_size % 2 == 0);
    const dst_size = src_size / 2;

    for (0..dst_size) |z| {
        for (0..dst_size) |y| {
            for (0..dst_size) |x|
                dst[voxelIndex(dst_size, x, y, z)] =
                    chooseBlockFrom2x2x2(src, src_size, x * 2, y * 2, z * 2);
        }
    }
}

// Maybe pass a ptr to avoid extra copy
fn generateVoxels(
    coord: @Vector(3, i32),
    size: usize,
    terrain_generator: *TerrainGenerator,
) ChunkLods {
    var out: ChunkLods = undefined;

    terrain_generator.fillChunkVoxels(out.lod0[0..], coord, size);
    buildLod(out.lod0[0..], CHUNK_SIZE, out.lod1[0..]);
    buildLod(out.lod1[0..], LOD1_CHUNK_SIZE, out.lod2[0..]);
    buildLod(out.lod2[0..], LOD2_CHUNK_SIZE, out.lod3[0..]);
    buildLod(out.lod3[0..], LOD3_CHUNK_SIZE, out.lod4[0..]);

    return out;
}

/// Expand voxel data to 32^3, needed only for now (I hope)
/// I find this elegant
fn expandTo32(
    dst: []BlockId,
    src: []const BlockId,
    src_size: usize,
) void {
    std.debug.assert(CHUNK_SIZE % src_size == 0);
    const scale = CHUNK_SIZE / src_size;

    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |x| {
                const sx = x / scale;
                const sy = y / scale;
                const sz = z / scale;

                dst[voxelIndex(CHUNK_SIZE, x, y, z)] =
                    src[voxelIndex(src_size, sx, sy, sz)];
            }
        }
    }
}

//// HANDLE BITFIELDS //////////////////////////////////////////////////////////

const Bitfield = u32;

pub const BitfieldViews = struct {
    solid_x: [CHUNK_SIZE][CHUNK_SIZE]Bitfield, // [y][z], bits are x
    solid_y: [CHUNK_SIZE][CHUNK_SIZE]Bitfield, // [x][z], bits are y
    solid_z: [CHUNK_SIZE][CHUNK_SIZE]Bitfield, // [x][y], bits are z
};

pub fn createBitfields(voxels: []BlockId) BitfieldViews {
    var bitfields_out = std.mem.zeroInit(BitfieldViews, .{});

    for (0..CHUNK_SIZE) |x_usize| {
        const x: u5 = @intCast(x_usize);
        const mx: u32 = @as(u32, 1) << x; // x mask

        for (0..CHUNK_SIZE) |y_usize| {
            const y: u5 = @intCast(y_usize);
            const my: u32 = @as(u32, 1) << y;

            for (0..CHUNK_SIZE) |z_usize| {
                const z: u5 = @intCast(z_usize);
                const mz: u32 = @as(u32, 1) << z;

                const idx = voxelIndex(CHUNK_SIZE, x_usize, y_usize, z_usize);
                if (voxels[idx] == BlockId.air) continue;

                bitfields_out.solid_x[y_usize][z_usize] |= mx;
                bitfields_out.solid_y[x_usize][z_usize] |= my;
                bitfields_out.solid_z[x_usize][y_usize] |= mz;
            }
        }
    }

    return bitfields_out;
}

//// MESH DATA /////////////////////////////////////////////////////////////////

const ChunkMeshes = struct {
    lod0: std.ArrayList(Quad),
    lod1: std.ArrayList(Quad),
    lod2: std.ArrayList(Quad),
    lod3: std.ArrayList(Quad),
    lod4: std.ArrayList(Quad),

    fn init(allocator: std.mem.Allocator) !ChunkMeshes {
        return .{
            .lod0 = try std.ArrayList(Quad).initCapacity(allocator, CHUNK_SIZE),
            .lod1 = try std.ArrayList(Quad).initCapacity(allocator, LOD1_CHUNK_SIZE),
            .lod2 = try std.ArrayList(Quad).initCapacity(allocator, LOD2_CHUNK_SIZE),
            .lod3 = try std.ArrayList(Quad).initCapacity(allocator, LOD3_CHUNK_SIZE),
            .lod4 = try std.ArrayList(Quad).initCapacity(allocator, LOD4_CHUNK_SIZE),
        };
    }

    fn deinit(self: *ChunkMeshes, allocator: std.mem.Allocator) void {
        self.lod0.deinit(allocator);
        self.lod1.deinit(allocator);
        self.lod2.deinit(allocator);
        self.lod3.deinit(allocator);
        self.lod4.deinit(allocator);
    }
};

//// MAIN //////////////////////////////////////////////////////////////////////

pub const Chunk = struct {
    coord: ChunkCoord,
    dimensions: usize,

    lods: ChunkLods,
    meshes: ChunkMeshes,

    dirty: bool = true,
    queued: bool = false,
    meshing: bool = false,

    // Only for LOD0
    bitfields: BitfieldViews,

    // aabb for culling
    world_min: ChunkCoord,
    world_max: ChunkCoord,

    fn markAdjacentChunksAsDirty(c: ChunkCoord, world: *World) void {
        if (world.getChunk(.{ c[0] + 1, c[1], c[2] })) |a| a.dirty = true;
        if (world.getChunk(.{ c[0] - 1, c[1], c[2] })) |a| a.dirty = true;
        if (world.getChunk(.{ c[0], c[1] + 1, c[2] })) |a| a.dirty = true;
        if (world.getChunk(.{ c[0], c[1] - 1, c[2] })) |a| a.dirty = true;
        if (world.getChunk(.{ c[0], c[1], c[2] + 1 })) |a| a.dirty = true;
        if (world.getChunk(.{ c[0], c[1], c[2] - 1 })) |a| a.dirty = true;
    }

    pub fn generate(
        allocator: std.mem.Allocator,
        coord: ChunkCoord,
        size: usize,
        world: *World,
        terrain_generator: *TerrainGenerator,
    ) !Chunk {
        const size_i = @as(i32, @intCast(size));
        const size_vec = @as(ChunkCoord, @splat(size_i));

        const world_min = coord * size_vec;
        const world_max = world_min + size_vec;

        var lods = generateVoxels(coord, size, terrain_generator);
        const bitfields = createBitfields(lods.lod0[0..]);

        const chunk = Chunk{
            .coord = coord,
            .lods = lods,

            .world_min = world_min,
            .world_max = world_max,
            .dimensions = size,
            .meshes = try ChunkMeshes.init(allocator),

            .bitfields = bitfields,
        };

        markAdjacentChunksAsDirty(coord, world);

        return chunk;
    }
};
