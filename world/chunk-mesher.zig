const std = @import("std");

const Chunk = @import("../Chunk.zig").Chunk;
const Atlas = @import("../Atlas.zig").Atlas;

const Block = @import("Block.zig");
const Quad = Block.Quad;
const BlockId = Block.BlockId;
const Face = Block.Face;

const types = @import("../math/types.zig");
const Vec3i = types.Vec3i;
const PosVec = @Vector(3, usize);

const UV = @Vector(2, usize);

fn buildBitFields(chunk: *Chunk) void {
    chunk.bitfields.clearBitfields();

    const chunk_size = chunk.dimensions;

    for (0..chunk_size) |x_usize| {
        const x: u5 = @intCast(x_usize); // consequently the max chunk size is 32
        const mx: u32 = @as(u32, 1) << x; // x mask

        for (0..chunk_size) |y_usize| {
            const y: u5 = @intCast(y_usize);
            const my: u32 = @as(u32, 1) << y;

            for (0..chunk_size) |z_usize| {
                const z: u5 = @intCast(z_usize);
                const mz: u32 = @as(u32, 1) << z;

                const idx = x_usize + y_usize * chunk_size +
                    z_usize * chunk_size * chunk_size;
                if (chunk.voxels[idx] == BlockId.air) continue;

                chunk.bitfields.solid_x[y_usize][z_usize] |= mx;
                chunk.bitfields.solid_y[x_usize][z_usize] |= my;
                chunk.bitfields.solid_z[x_usize][y_usize] |= mz;
            }
        }
    }
}

////////////////////////////////////////////////////////////////////////////////

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

    inline fn visiblePos(row: u32) u32 {
        return row & ~(row >> 1);
    }

    inline fn visibleNeg(row: u32) u32 {
        return row & ~(row << 1);
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

    fn emitXFaces(
        self: *const Mesher,
        chunk: *const Chunk,
        mesh: *std.ArrayList(Quad),
        allocator: std.mem.Allocator,
    ) !void {
        const size = chunk.dimensions;
        const voxels = chunk.voxels;

        for (0..size) |y| {
            for (0..size) |z| {
                const row = chunk.bitfields.solid_x[y][z];

                var pos_mask = visiblePos(row);
                while (pos_mask != 0) {
                    const x: usize = @intCast(@ctz(pos_mask));
                    pos_mask &= pos_mask - 1;
                    try appendQuad(self, mesh, allocator, voxels, size, .right, x, y, z);
                }

                var neg_mask = visibleNeg(row);
                while (neg_mask != 0) {
                    const x: usize = @intCast(@ctz(neg_mask));
                    neg_mask &= neg_mask - 1;
                    try appendQuad(self, mesh, allocator, voxels, size, .left, x, y, z);
                }
            }
        }
    }

    fn emitYFaces(
        self: *const Mesher,
        chunk: *const Chunk,
        mesh: *std.ArrayList(Quad),
        allocator: std.mem.Allocator,
    ) !void {
        const size = chunk.dimensions;
        const voxels = chunk.voxels;

        for (0..size) |x| {
            for (0..size) |z| {
                const row = chunk.bitfields.solid_y[x][z];

                var pos_mask = visiblePos(row);
                while (pos_mask != 0) {
                    const y: usize = @intCast(@ctz(pos_mask));
                    pos_mask &= pos_mask - 1;
                    try appendQuad(self, mesh, allocator, voxels, size, .top, x, y, z);
                }

                var neg_mask = visibleNeg(row);
                while (neg_mask != 0) {
                    const y: usize = @intCast(@ctz(neg_mask));
                    neg_mask &= neg_mask - 1;
                    try appendQuad(self, mesh, allocator, voxels, size, .bottom, x, y, z);
                }
            }
        }
    }

    fn emitZFaces(
        self: *const Mesher,
        chunk: *const Chunk,
        mesh: *std.ArrayList(Quad),
        allocator: std.mem.Allocator,
    ) !void {
        const size = chunk.dimensions;
        const voxels = chunk.voxels;

        for (0..size) |x| {
            for (0..size) |y| {
                const row = chunk.bitfields.solid_z[x][y];

                var pos_mask = visiblePos(row);
                while (pos_mask != 0) {
                    const z: usize = @intCast(@ctz(pos_mask));
                    pos_mask &= pos_mask - 1;
                    try appendQuad(self, mesh, allocator, voxels, size, .back, x, y, z);
                }

                var neg_mask = visibleNeg(row);
                while (neg_mask != 0) {
                    const z: usize = @intCast(@ctz(neg_mask));
                    neg_mask &= neg_mask - 1;
                    try appendQuad(self, mesh, allocator, voxels, size, .front, x, y, z);
                }
            }
        }
    }

    pub fn generateMesh(self: *const Mesher, chunk: *Chunk, allocator: std.mem.Allocator) !void {
        const size = chunk.dimensions;

        var mesh = try std.ArrayList(Quad).initCapacity(allocator, size);

        buildBitFields(chunk);

        try self.emitXFaces(chunk, &mesh, allocator);
        try self.emitYFaces(chunk, &mesh, allocator);
        try self.emitZFaces(chunk, &mesh, allocator);

        chunk.mesh.clearAndFree(allocator);
        chunk.mesh = mesh;
    }
};
