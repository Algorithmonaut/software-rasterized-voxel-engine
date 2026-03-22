const std = @import("std");
const Float = @import("math/types.zig").Float;
const BlockType = @import("Atlas.zig").BlockTypes;

const ChunkCoord = @import("math/types.zig").ChunkCoord;
const World = @import("World.zig").World;

const Block = @import("world/Block.zig");
const Quad = Block.Quad;
const BlockId = Block.BlockId;

const chunk_size = 32;
const Bitfield = u32; // TODO: Make the generation of this dependant on the chunk size

pub const BitfieldViews = struct {
    solid_x: [chunk_size][chunk_size]Bitfield, // [y][z], bits are x
    solid_y: [chunk_size][chunk_size]Bitfield, // [x][z], bits are y
    solid_z: [chunk_size][chunk_size]Bitfield, // [x][y], bits are z

    pub fn clearBitfields(self: *BitfieldViews) void {
        for (0..chunk_size) |a| {
            for (0..chunk_size) |b| {
                self.solid_x[a][b] = 0;
                self.solid_y[a][b] = 0;
                self.solid_z[a][b] = 0;
            }
        }
    }
};

pub const Chunk = struct {
    coord: ChunkCoord,

    dimensions: usize,

    voxels: []BlockId,

    dirty: bool = true,
    meshed: bool = false,

    mesh: std.ArrayList(Quad),

    // output of meshing
    face_count: usize = 0,

    bitfields: BitfieldViews,

    // aabb for culling
    world_min: ChunkCoord,
    world_max: ChunkCoord,

    pub fn buildBitfields(self: *Chunk) void {
        const size = self.dimensions;

        for (0..size) |x_usize| {
            const x: u5 = @intCast(x_usize); // consequently the max chunk size is 32
            const mx: u32 = @as(u32, 1) << x; // x mask

            for (0..size) |y_usize| {
                const y: u5 = @intCast(y_usize);
                const my: u32 = @as(u32, 1) << y;

                for (0..size) |z_usize| {
                    const z: u5 = @intCast(z_usize);
                    const mz: u32 = @as(u32, 1) << z;

                    const idx = x_usize + y_usize * size + z_usize * size * size;
                    if (self.voxels[idx] == BlockId.air) continue;

                    self.bitfields.solid_x[y_usize][z_usize] |= mx;
                    self.bitfields.solid_y[x_usize][z_usize] |= my;
                    self.bitfields.solid_z[x_usize][y_usize] |= mz;
                }
            }
        }
    }

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
    ) !Chunk {
        const size_i = @as(i32, @intCast(size));
        const size_vec = @as(ChunkCoord, @splat(size_i));

        const world_min = coord * size_vec;
        const world_max = world_min + size_vec;

        const voxels = try allocator.alloc(BlockId, size * size * size);

        for (0..voxels.len) |i| voxels[i] = @enumFromInt(i % 3);

        var chunk = Chunk{
            .coord = coord,
            .voxels = voxels,

            .world_min = world_min,
            .world_max = world_max,
            .dimensions = size,
            .mesh = try std.ArrayList(Quad).initCapacity(allocator, 0),

            .bitfields = undefined,
        };

        chunk.buildBitfields();
        markAdjacentChunksAsDirty(coord, world);

        return chunk;
    }

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.voxels);
    }
};
