const std = @import("std");

const RasterTriangle = @import("triangle.zig").RasterTriangle;
const Chunk = @import("world/Chunk.zig").Chunk;
const RenderQuad = @import("mesh/Mesh.zig").RenderQuad;

const CHUNK_SIZE = @import("world/Chunk.zig").CHUNK_SIZE;
const TEX_SIZE = @import("Atlas.zig").TEX_SIZE;

const PlaneKind = @import("mesh/Mesh.zig").PlaneKind;

const types = @import("math/types.zig");
const F3 = types.Vec3f;
const F4 = types.Vec4f;
const I3 = types.Vec3i;
const WorldQuad = @import("world/Block.zig").WorldQuad;
const WorldVertex = @import("world/Block.zig").WorldVertex;

const Mat4f = @import("math/matrix.zig").Mat4f;

// TODO: Centralize this
const UV = @Vector(2, f32);

const eps: f32 = 0.0001;

var triangles: std.ArrayList(RasterTriangle) = .empty;

//// PRIMITIVE BUILDING & CULLING //////////////////////////////////////////////

inline fn clipCode(v: F4) u8 {
    var code: u8 = 0; // bitfield
    if (v[0] < -v[3]) code |= 1 << 0; // left
    if (v[0] > v[3]) code |= 1 << 1; // right
    if (v[1] < -v[3]) code |= 1 << 2; // bottom
    if (v[1] > v[3]) code |= 1 << 3; // top
    if (v[2] < 0) code |= 1 << 4; // near
    return code;
}

fn emitRenderQuad(
    comptime kind: PlaneKind,
    rq: RenderQuad,
    chunk_min: F3,
    combined_mat: Mat4f,
) WorldQuad {
    const fx = chunk_min[0];
    const fy = chunk_min[1];
    const fz = chunk_min[2];

    const fixed: f32 = @floatFromInt(rq.fixed);
    const row0: f32 = @floatFromInt(rq.row);
    const col0: f32 = @floatFromInt(rq.col);
    const h: f32 = @floatFromInt(rq.height);
    const w: f32 = @floatFromInt(rq.width);

    const u_0: f32 = 0.0;
    const v_0: f32 = 0.0;
    const u_1: f32 = w * TEX_SIZE;
    const v_1: f32 = h * TEX_SIZE;

    var verts_coord: [4]F4 = switch (kind) {
        // x = const, y=row, z=col
        .pos_x => .{
            .{ fx + fixed + 1.0, fy + row0, fz + col0, 0 },
            .{ fx + fixed + 1.0, fy + row0 + h, fz + col0, 0 },
            .{ fx + fixed + 1.0, fy + row0 + h, fz + col0 + w, 0 },
            .{ fx + fixed + 1.0, fy + row0, fz + col0 + w, 0 },
        },
        .neg_x => .{
            .{ fx + fixed, fy + row0, fz + col0, 0 },
            .{ fx + fixed, fy + row0, fz + col0 + w, 0 },
            .{ fx + fixed, fy + row0 + h, fz + col0 + w, 0 },
            .{ fx + fixed, fy + row0 + h, fz + col0, 0 },
        },

        // y = const, x=row, z=col
        .pos_y => .{
            .{ fx + row0, fy + fixed + 1.0, fz + col0, 0 },
            .{ fx + row0, fy + fixed + 1.0, fz + col0 + w, 0 },
            .{ fx + row0 + h, fy + fixed + 1.0, fz + col0 + w, 0 },
            .{ fx + row0 + h, fy + fixed + 1.0, fz + col0, 0 },
        },
        .neg_y => .{
            .{ fx + row0, fy + fixed, fz + col0, 0 },
            .{ fx + row0 + h, fy + fixed, fz + col0, 0 },
            .{ fx + row0 + h, fy + fixed, fz + col0 + w, 0 },
            .{ fx + row0, fy + fixed, fz + col0 + w, 0 },
        },

        // z = const, x=row, y=col
        .pos_z => .{
            .{ fx + row0, fy + col0, fz + fixed + 1.0, 0 },
            .{ fx + row0 + h, fy + col0, fz + fixed + 1.0, 0 },
            .{ fx + row0 + h, fy + col0 + w, fz + fixed + 1.0, 0 },
            .{ fx + row0, fy + col0 + w, fz + fixed + 1.0, 0 },
        },
        .neg_z => .{
            .{ fx + row0, fy + col0, fz + fixed, 0 },
            .{ fx + row0, fy + col0 + w, fz + fixed, 0 },
            .{ fx + row0 + h, fy + col0 + w, fz + fixed, 0 },
            .{ fx + row0 + h, fy + col0, fz + fixed, 0 },
        },
    };

    // World → raster
    verts_coord[0] = combined_mat.mul_vec(verts_coord[0]);
    verts_coord[1] = combined_mat.mul_vec(verts_coord[1]);
    verts_coord[2] = combined_mat.mul_vec(verts_coord[2]);
    verts_coord[3] = combined_mat.mul_vec(verts_coord[3]);

    const c0 = clipCode(verts_coord[0]);
    const c1 = clipCode(verts_coord[1]);
    const c2 = clipCode(verts_coord[2]);
    const c3 = clipCode(verts_coord[3]);

    const or_code = c0 | c1 | c2 | c3;
    const and_code = c0 & c1 & c2 & c3;

    if (and_code != 0) return; // quad trivially outside

    const verts_uv: [4]UV = switch (kind) {
        .pos_x => .{ .{ u_0, v_0 }, .{ u_0, v_1 }, .{ u_1, v_1 }, .{ u_1, v_0 } },
        .neg_x => .{ .{ u_0, v_0 }, .{ u_1, v_0 }, .{ u_1, v_1 }, .{ u_0, v_1 } },
        .pos_y => .{ .{ u_0, v_0 }, .{ u_1, v_0 }, .{ u_1, v_1 }, .{ u_0, v_1 } },
        .neg_y => .{ .{ u_0, v_0 }, .{ u_1, v_0 }, .{ u_1, v_1 }, .{ u_0, v_1 } },
        .pos_z => .{ .{ u_0, v_0 }, .{ u_1, v_0 }, .{ u_1, v_1 }, .{ u_0, v_1 } },
        .neg_z => .{ .{ u_0, v_0 }, .{ u_1, v_0 }, .{ u_1, v_1 }, .{ u_0, v_1 } },
    };

    if (or_code == 0) {
        const quad = WorldQuad{
            .tex_tile_size = 16,
            .tex_u = 
        }

        try emitQuad(self, allocator, quad);
        return;
    }
}

//// TRIVIAL, PLANE NORMAL BASED CULLING | AXIS BUCKET CULL ////////////////////

fn emitBucket(
    comptime kind: PlaneKind,
    quads: []const RenderQuad,
    cam_axis: f32,
    slab_min: f32,
    slab_max: f32,
    combined_mat: Mat4f,
) void {

    // POSITIVE AXIS (box is chunk)
    //             ┌───┐
    //  -  ────────┼───┼───────▶  +
    //             └───┘
    //     ▲         ▲         ▲
    //     no faces  test all  all faces
    //     visible   faces     visible

    // NEGATIVE AXIS (box is chunk):
    //             ┌───┐
    //  -  ────────┼───┼───────▶  +
    //             └───┘
    //     ▲         ▲         ▲
    //     all faces test all  no faces
    //     visible   faces     visible

    // All faces are visible
    if (switch (kind) {
        .pos_x, .pos_y, .pos_z => cam_axis > slab_max,
        .neg_x, .neg_y, .neg_z => cam_axis < slab_min,
    }) {
        for (quads) |quad| emitRenderQuad(quad, combined_mat);
        return;
    }

    // No faces are visible
    if (cam_axis <= slab_min or cam_axis >= slab_max) return;

    // Test all faces
    const positive = switch (kind) {
        .pos_x, .pos_y, .pos_z => true,
        .neg_x, .neg_y, .neg_z => false,
    };

    for (quads) |quad| {
        const fixed: f32 = @floatFromInt(quad.fixed);

        // Face's world space coordinate on its fixed axis.
        const axis_world_coord: f32 = switch (kind) {
            .pos_x, .pos_y, .pos_z => slab_min + fixed + 1,
            .neg_x, .neg_y, .neg_z => slab_min + fixed,
        };

        if (positive) {
            if (cam_axis > axis_world_coord + eps) emitRenderQuad(
                quad,
                combined_mat,
            );
        } else {
            if (cam_axis < axis_world_coord - eps) emitRenderQuad(
                quad,
                combined_mat,
            );
        }
    }
}

pub fn generatePrimitivesFromChunk(chunk: *Chunk, camera_pos: F3, combined_mat: Mat4f) void {
    const min: F3 = @floatFromInt(chunk.world_min);
    const max: F3 = @floatFromInt(chunk.world_max);
    const pos = camera_pos;

    emitBucket(.pos_x, chunk.mesh.pos_x_faces.items, pos[0], min[0], max[0], min, combined_mat);
    emitBucket(.pos_y, chunk.mesh.pos_y_faces.items, pos[1], min[1], max[1], min, combined_mat);
    emitBucket(.pos_z, chunk.mesh.pos_z_faces.items, pos[2], min[2], max[2], min, combined_mat);
    emitBucket(.neg_x, chunk.mesh.neg_x_faces.items, pos[0], min[0], max[0], min, combined_mat);
    emitBucket(.neg_y, chunk.mesh.neg_y_faces.items, pos[1], min[1], max[1], min, combined_mat);
    emitBucket(.neg_z, chunk.mesh.neg_z_faces.items, pos[2], min[2], max[2], min, combined_mat);
}
