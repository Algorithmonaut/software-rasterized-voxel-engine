const std = @import("std");

const Chunk = @import("../Chunk.zig").Chunk;
const Atlas = @import("../Atlas.zig").Atlas;
const World = @import("../World.zig").World;

const Block = @import("Block.zig");
const Quad = Block.Quad;
const BlockId = Block.BlockId;
const Face = Block.Face;

const types = @import("../math/types.zig");
const Vec3i = types.Vec3i;
const PosVec = @Vector(3, usize);

const UV = @Vector(2, usize);

const PlaneSet = [32][32]u32;

// NOTE: For simplicity and to avoid mixing chunk coordinates / textures coordinates
// maybe use this (much simpler) architecture:

// const FaceTemplate = struct {
//     p0: Vec3i,
//     p1: Vec3i,
//     p2: Vec3i,
//     p3: Vec3i,
// };
//
// const face_templates = [6]FaceTemplate{
//     .{ .p0 = .{ 1, 0, 1 }, .p1 = .{ 1, 1, 1 }, .p2 = .{ 0, 1, 1 }, .p3 = .{ 0, 0, 1 } }, // back
//     .{ .p0 = .{ 0, 0, 0 }, .p1 = .{ 0, 1, 0 }, .p2 = .{ 1, 1, 0 }, .p3 = .{ 1, 0, 0 } }, // front
//     .{ .p0 = .{ 0, 0, 1 }, .p1 = .{ 0, 1, 1 }, .p2 = .{ 0, 1, 0 }, .p3 = .{ 0, 0, 0 } }, // left
//     .{ .p0 = .{ 1, 0, 0 }, .p1 = .{ 1, 1, 0 }, .p2 = .{ 1, 1, 1 }, .p3 = .{ 1, 0, 1 } }, // right
//     .{ .p0 = .{ 0, 0, 1 }, .p1 = .{ 0, 0, 0 }, .p2 = .{ 1, 0, 0 }, .p3 = .{ 1, 0, 1 } }, // bottom
//     .{ .p0 = .{ 0, 1, 0 }, .p1 = .{ 0, 1, 1 }, .p2 = .{ 1, 1, 1 }, .p3 = .{ 1, 1, 0 } }, // top
// };

// NOTE: Also maybe make the mesher stateless

const UvCoord = struct {
    left: usize,
    right: usize,
    top: usize,
    bottom: usize,
};

pub const Mesher = struct {
    face_offsets: [6]Quad,

    fn makeQuad(
        p0: PosVec, // bottom-left
        p1: PosVec, // top-left
        p2: PosVec, // top-right
        p3: PosVec, // bottom-right
        uv: UvCoord,
    ) Quad {
        return .{
            .v0 = .{ .pos = p0, .uv = .{ uv.left, uv.bottom } },
            .v1 = .{ .pos = p1, .uv = .{ uv.left, uv.top } },
            .v2 = .{ .pos = p2, .uv = .{ uv.right, uv.top } },
            .v3 = .{ .pos = p3, .uv = .{ uv.right, uv.bottom } },
        };
    }

    fn faceUv(face: Face, tex_w: usize, tex_h: usize) UvCoord {
        const left = @intFromEnum(face) * tex_w;
        return .{
            .left = left,
            .right = left + tex_w - 1,
            .top = 0,
            .bottom = tex_h - 1,
        };
    }

    pub fn init(atlas: *const Atlas) Mesher {
        var offsets: [6]Quad = undefined;

        // Back face
        offsets[@intFromEnum(Face.back)] = makeQuad(
            .{ 1, 0, 1 },
            .{ 1, 1, 1 },
            .{ 0, 1, 1 },
            .{ 0, 0, 1 },
            faceUv(Face.back, atlas.tex_w, atlas.tex_h),
        );

        // Front face
        offsets[@intFromEnum(Face.front)] = makeQuad(
            .{ 0, 0, 0 },
            .{ 0, 1, 0 },
            .{ 1, 1, 0 },
            .{ 1, 0, 0 },
            faceUv(Face.front, atlas.tex_w, atlas.tex_h),
        );

        // Left face
        offsets[@intFromEnum(Face.left)] = makeQuad(
            .{ 0, 0, 1 },
            .{ 0, 1, 1 },
            .{ 0, 1, 0 },
            .{ 0, 0, 0 },
            faceUv(Face.left, atlas.tex_w, atlas.tex_h),
        );

        // Right face
        offsets[@intFromEnum(Face.right)] = makeQuad(
            .{ 1, 0, 0 },
            .{ 1, 1, 0 },
            .{ 1, 1, 1 },
            .{ 1, 0, 1 },
            faceUv(Face.right, atlas.tex_w, atlas.tex_h),
        );

        // Bottom face
        offsets[@intFromEnum(Face.bottom)] = makeQuad(
            .{ 0, 0, 1 },
            .{ 0, 0, 0 },
            .{ 1, 0, 0 },
            .{ 1, 0, 1 },
            faceUv(Face.bottom, atlas.tex_w, atlas.tex_h),
        );

        // Top face
        offsets[@intFromEnum(Face.top)] = makeQuad(
            .{ 0, 1, 0 },
            .{ 0, 1, 1 },
            .{ 1, 1, 1 },
            .{ 1, 1, 0 },
            faceUv(Face.top, atlas.tex_w, atlas.tex_h),
        );

        return .{
            .face_offsets = offsets,
        };
    }

    // MESHER //////////////////////////////////////////////////////////////////

    fn generateQuadCoordinates(
        quad_offset: Quad,
        x: usize,
        y: usize,
        z: usize,
        block_id: BlockId,
    ) Quad {
        const offset: PosVec = .{ x, y, z };
        var quad = quad_offset;

        quad.v0.pos += offset;
        quad.v1.pos += offset;
        quad.v2.pos += offset;
        quad.v3.pos += offset;
        quad.v0.uv[1] += @intFromEnum(block_id) * 16;
        quad.v1.uv[1] += @intFromEnum(block_id) * 16;
        quad.v2.uv[1] += @intFromEnum(block_id) * 16;
        quad.v3.uv[1] += @intFromEnum(block_id) * 16;

        return quad;
    }

    inline fn voxelIndex(size: usize, x: usize, y: usize, z: usize) usize {
        return x + y * size + z * size * size;
    }

    // TODO: Find if not generating quads when adjacent chunk is not yet
    // generated is better
    inline fn visiblePos(row: u32) u32 {
        return row & ~(row >> 1);
    }

    inline fn visibleNeg(row: u32) u32 {
        return row & ~(row << 1);
    }

    fn visiblePosWithNeighbor(row: u32, neighbor_first_bit: u32) u32 {
        const shifted = (row >> 1) | (neighbor_first_bit << 31);
        return row & ~shifted;
    }

    fn visibleNegWithNeighbor(row: u32, neighbor_last_bit: u32) u32 {
        const shifted = (row << 1) | neighbor_last_bit;
        return row & ~shifted;
    }

    inline fn appendQuad(
        self: *const Mesher,
        mesh: *std.ArrayList(Quad),
        allocator: std.mem.Allocator,
        voxels: []const BlockId,
        size: usize,
        face: Face,
        x: usize,
        y: usize,
        z: usize,
    ) !void {
        const id = voxels[voxelIndex(size, x, y, z)];
        const quad = generateQuadCoordinates(
            self.face_offsets[@intFromEnum(face)],
            x,
            y,
            z,
            id,
        );
        try mesh.append(allocator, quad);
    }

    //// X AXIS ////

    fn scatterMaskX(
        planes: *PlaneSet,
        y: usize,
        z: usize,
        mask_in: u32,
    ) void {
        var mask = mask_in;
        while (mask != 0) {
            const x: usize = @ctz(mask);
            mask &= mask - 1;
            planes[x][y] |= (@as(u32, 1)) << @intCast(z);
        }
    }

    fn buildXPlanes(
        chunk: *const Chunk,
        world: *World,
        pos_x_planes: *PlaneSet,
        neg_x_planes: *PlaneSet,
    ) void {
        const size = chunk.dimensions;

        const pos_neighbor = world.getChunk(.{
            chunk.coord[0] + 1,
            chunk.coord[1],
            chunk.coord[2],
        });

        const neg_neighbor = world.getChunk(.{
            chunk.coord[0] - 1,
            chunk.coord[1],
            chunk.coord[2],
        });

        if (pos_neighbor) |adjacent| std.debug.assert(!adjacent.dirty);
        if (neg_neighbor) |adjacent| std.debug.assert(!adjacent.dirty);

        for (0..size) |y| {
            for (0..size) |z| {
                const row = chunk.bitfields.solid_x[y][z];

                const pos_mask = if (pos_neighbor) |adjacent|
                    visiblePosWithNeighbor(row, adjacent.bitfields.solid_x[y][z] & @as(u32, 1))
                else
                    visiblePos(row);

                const neg_mask = if (neg_neighbor) |adjacent|
                    visibleNegWithNeighbor(row, (adjacent.bitfields.solid_x[y][z] >> 31) & @as(u32, 1))
                else
                    visibleNeg(row);

                scatterMaskX(pos_x_planes, y, z, pos_mask);
                scatterMaskX(neg_x_planes, y, z, neg_mask);
            }
        }
    }

    //// Y AXIS ////

    fn scatterMaskY(
        planes: *PlaneSet,
        x: usize,
        z: usize,
        mask_in: u32,
    ) void {
        var mask = mask_in;
        while (mask != 0) {
            const y: usize = @ctz(mask);
            mask &= mask - 1;
            planes[y][x] |= (@as(u32, 1)) << @intCast(z);
        }
    }

    fn buildYPlanes(
        chunk: *const Chunk,
        world: *World,
        pos_y_planes: *PlaneSet,
        neg_y_planes: *PlaneSet,
    ) void {
        const size = chunk.dimensions;

        const pos_neighbor = world.getChunk(.{
            chunk.coord[0],
            chunk.coord[1] + 1,
            chunk.coord[2],
        });

        const neg_neighbor = world.getChunk(.{
            chunk.coord[0],
            chunk.coord[1] - 1,
            chunk.coord[2],
        });

        if (pos_neighbor) |adjacent| std.debug.assert(!adjacent.dirty);
        if (neg_neighbor) |adjacent| std.debug.assert(!adjacent.dirty);

        for (0..size) |x| {
            for (0..size) |z| {
                const row = chunk.bitfields.solid_y[x][z];

                const pos_mask = if (pos_neighbor) |adjacent|
                    visiblePosWithNeighbor(row, adjacent.bitfields.solid_y[x][z] & @as(u32, 1))
                else
                    visiblePos(row);

                const neg_mask = if (neg_neighbor) |adjacent|
                    visibleNegWithNeighbor(row, (adjacent.bitfields.solid_y[x][z] >> 31) & @as(u32, 1))
                else
                    visibleNeg(row);

                scatterMaskY(pos_y_planes, x, z, pos_mask);
                scatterMaskY(neg_y_planes, x, z, neg_mask);
            }
        }
    }

    //// Z AXIS ////

    fn scatterMaskZ(
        planes: *PlaneSet,
        x: usize,
        y: usize,
        mask_in: u32,
    ) void {
        var mask = mask_in;
        while (mask != 0) {
            const z: usize = @ctz(mask);
            mask &= mask - 1;
            planes[z][x] |= (@as(u32, 1)) << @intCast(y);
        }
    }

    fn buildZPlanes(
        chunk: *const Chunk,
        world: *World,
        pos_z_planes: *PlaneSet,
        neg_z_planes: *PlaneSet,
    ) void {
        const size = chunk.dimensions;

        const pos_neighbor = world.getChunk(.{
            chunk.coord[0],
            chunk.coord[1],
            chunk.coord[2] + 1,
        });

        const neg_neighbor = world.getChunk(.{
            chunk.coord[0],
            chunk.coord[1],
            chunk.coord[2] - 1,
        });

        if (pos_neighbor) |adjacent| std.debug.assert(!adjacent.dirty);
        if (neg_neighbor) |adjacent| std.debug.assert(!adjacent.dirty);

        for (0..size) |x| {
            for (0..size) |y| {
                const row = chunk.bitfields.solid_z[x][y];

                const pos_mask = if (pos_neighbor) |adjacent|
                    visiblePosWithNeighbor(row, adjacent.bitfields.solid_z[x][y] & @as(u32, 1))
                else
                    visiblePos(row);

                const neg_mask = if (neg_neighbor) |adjacent|
                    visibleNegWithNeighbor(row, (adjacent.bitfields.solid_z[x][y] >> 31) & @as(u32, 1))
                else
                    visibleNeg(row);

                scatterMaskY(pos_z_planes, x, y, pos_mask);
                scatterMaskY(neg_z_planes, x, y, neg_mask);
            }
        }
    }

    pub fn generateMesh(
        self: *const Mesher,
        chunk: *Chunk,
        world: *World,
        allocator: std.mem.Allocator,
    ) !void {
        var pos_x_planes: PlaneSet = [_][32]u32{[_]u32{0} ** 32} ** 32;
        var neg_x_planes: PlaneSet = [_][32]u32{[_]u32{0} ** 32} ** 32;

        var pos_y_planes: PlaneSet = [_][32]u32{[_]u32{0} ** 32} ** 32;
        var neg_y_planes: PlaneSet = [_][32]u32{[_]u32{0} ** 32} ** 32;

        var pos_z_planes: PlaneSet = [_][32]u32{[_]u32{0} ** 32} ** 32;
        var neg_z_planes: PlaneSet = [_][32]u32{[_]u32{0} ** 32} ** 32;

        const size = chunk.dimensions;

        var mesh = try std.ArrayList(Quad).initCapacity(allocator, size);

        buildXPlanes(chunk, world, &pos_x_planes, &neg_x_planes);
        buildYPlanes(chunk, world, &pos_y_planes, &neg_y_planes);
        buildZPlanes(chunk, world, &pos_z_planes, &neg_z_planes);

        for (0..size) |x| {
            try self.greedyMergePosXPlane(
                &mesh,
                allocator,
                chunk.voxels,
                size,
                x,
                pos_x_planes[x],
            );
        }

        chunk.mesh.clearAndFree(allocator);
        chunk.mesh = mesh;
    }

    //// GREEDY MESHER /////////////////////////////////////////////////////////////

    /// Returns a bitmask with exactly width consecutive 1s starting at bit start.
    fn rectMask(start: usize, width: usize) u32 {
        if (width >= 32) return std.math.maxInt(u32);
        // Example with start = 3, width = 4
        // STEP 1 | 0b00000001
        // STEP 2 | 0b00010000
        // STEP 3 | 0b00001111
        // STEP 4 | 0b01111000
        return ((@as(u32, 1) << @intCast(width)) - 1) << @intCast(start);
    }

    /// Counts how many consecutive 1 bits appear in mask, starting at bit start
    fn runWidthFromSlow(mask: u32, start: usize, size: usize) usize {
        var width: usize = 0;
        var i = start;
        while (i < size) : (i += 1) {
            const bit = (@as(u32, 1) << @intCast(i));
            if ((mask & bit) == 0) break;
            width += 1;
        }

        return width;
    }

    fn greedyMergePosXPlane(
        self: *const Mesher,
        mesh: *std.ArrayList(Quad),
        allocator: std.mem.Allocator,
        voxels: []const BlockId,
        size: usize,
        x: usize,
        plane_in: [32]u32,
    ) !void {
        var plane = plane_in;

        var y0: usize = 0;
        while (y0 < size) : (y0 += 1) {
            while (plane[y0] != 0) {
                const z0: usize = @intCast(@ctz(plane[y0]));
                const id0 = voxels[voxelIndex(size, x, y0, z0)];

                var width = runWidthFromSlow(plane[y0], z0, size);

                var z = z0;
                while (z < z0 + width) : (z += 1) {
                    const id = voxels[voxelIndex(size, x, y0, z)];
                    if (id != id0) {
                        width = z - z0;
                        break;
                    }
                }

                const mask = rectMask(z0, width);

                var height: usize = 1;
                while (y0 + height < size) {
                    if ((plane[y0 + height] & mask) != mask) break;

                    var ok = true;
                    z = z0;
                    while (z < z0 + width) : (z += 1) {
                        const id = voxels[voxelIndex(size, x, y0 + height, z)];
                        if (id != id0) {
                            ok = false;
                            break;
                        }
                    }
                    if (!ok) break;

                    height += 1;
                }

                try self.appendQuad(
                    mesh,
                    allocator,
                    voxels,
                    size,
                    Face.right,
                    x,
                    y0,
                    z0,
                );

                //     self,
                //     mesh,
                //     allocator,
                //     Face.right,
                //     x,
                //     y0,
                //     z0,
                //     width, // along z
                //     height, // along y
                //     id0,
                // );

                var yy = y0;
                while (yy < y0 + height) : (yy += 1) {
                    plane[yy] &= ~mask;
                }
            }
        }
    }
};
