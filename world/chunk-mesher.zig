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

    fn generateQuadCoordinates(
        quad_offset: Quad,
        x: usize,
        y: usize,
        z: usize,
    ) Quad {
        const offset: PosVec = .{ x, y, z };
        var quad = quad_offset;

        quad.v0.pos += offset;
        quad.v1.pos += offset;
        quad.v2.pos += offset;
        quad.v3.pos += offset;

        return quad;
    }

    pub fn generateMesh(self: *const Mesher, chunk: *Chunk, allocator: std.mem.Allocator) !void {
        const size = chunk.dimensions;
        const voxels = chunk.voxels;

        const stride_y = size;
        const stride_z = size * size;

        var mesh = try std.ArrayList(Quad).initCapacity(allocator, size);

        for (0..size) |z| {
            const z_base = z * stride_z;

            for (0..size) |y| {
                const y_base = z_base + y * stride_y;

                for (0..size) |x| {
                    const i = y_base + x;

                    const id = voxels[i];
                    if (id == .air) continue;

                    for (0..6) |face| {
                        const quad = generateQuadCoordinates(
                            self.face_offsets[face],
                            x,
                            y,
                            z,
                        );
                        try mesh.append(allocator, quad);
                    }
                }
            }
        }

        chunk.mesh.clearAndFree(allocator);
        chunk.mesh = mesh;
    }
};
