const std = @import("std");

const Cube = @import("../Cube.zig").Cube;
const Chunk = @import("../Chunk.zig").Chunk;
const Atlas = @import("../Atlas.zig").Atlas;

const Block = @import("Block.zig");
const Quad = Block.Quad;
const BlockId = Block.BlockId;
const Vertex = Block.Vertex;
const Face = Block.Face;

const types = @import("../math/types.zig");
const Vec3i = types.Vec3i;

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

pub const Mesher = struct {
    face_offsets: [6]Quad,

    fn makeQuad(
        p0: Vec3i, // bottom-left
        p1: Vec3i, // top-left
        p2: Vec3i, // top-right
        p3: Vec3i, // bottom-right
        uv: struct { left: usize, right: usize, top: usize, bottom: usize },
    ) Quad {
        return .{
            .v0 = .{ .pos = p0, .uv = .{ uv.left, uv.bottom } },
            .v1 = .{ .pos = p1, .uv = .{ uv.left, uv.top } },
            .v2 = .{ .pos = p2, .uv = .{ uv.right, uv.top } },
            .v3 = .{ .pos = p3, .uv = .{ uv.right, uv.bottom } },
        };
    }

    fn faceUv(face: Face, tex_w: usize, tex_h: usize) struct {
        left: usize,
        right: usize,
        top: usize,
        bottom: usize,
    } {
        const left = @intFromEnum(face) * tex_w;
        return .{
            .left = left,
            .right = left + tex_w,
            .top = 0,
            .bottom = tex_h,
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

    // pub fn generateMesh(chunk: *Chunk, atlas: *Atlas, allocator: std.mem.Allocator) void {
    //     const size = chunk.dimensions;
    //
    //     const mesh = std.ArrayList(Quad).init(allocator, size);
    //
    //     for (0..chunk.voxels.len) |i| {
    //         const x = i % size;
    //         const y = (i / size) % size;
    //         const z = i % (size * size);
    //
    //         const id: BlockId = @enumFromInt(chunk.voxels[i]);
    //     }
};
