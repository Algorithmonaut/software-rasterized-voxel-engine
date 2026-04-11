const std = @import("std");

const RasterTriangle = @import("triangle.zig").RasterTriangle;
const Chunk = @import("world/Chunk.zig").Chunk;
const RenderQuad = @import("mesh/Mesh.zig").RenderQuad;
const CHUNK_SIZE = @import("world/Chunk.zig").CHUNK_SIZE;

const PlaneKind = @import("mesh/Mesh.zig").PlaneKind;

const types = @import("math/types.zig");
const F3 = types.Vec3f;
const I3 = types.Vec3i;

const eps: f32 = 0.0001;

var triangles: std.ArrayList(RasterTriangle) = .empty;

//// PRIMITIVE BUILDING & CULLING //////////////////////////////////////////////

inline fn emitRenderQuad() void {}

//// TRIVIAL, PLANE NORMAL BASED CULLING | AXIS BUCKET CULL ////////////////////

fn emitBucket(
    quads: []const RenderQuad,
    kind: PlaneKind,
    cam_axis: f32,
    slab_min: f32,
    slab_max: f32,
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
        for (quads) |quad| emitRenderQuad(quad);
        return;
    }

    // No faces are visible
    if (cam_axis <= slab_min or cam_axis >= slab_max) return;

    // Test all faces
    for (quads) |quad| {
        const f: i32 = @intCast(quad.fixed);

        // Face's constant world space coordinate on its fixed axis.
        const axis_world_coord: i32 = switch (kind) {
            .pos_x => slab_min + f + 1,
            .neg_x => slab_min + f,
            .pos_y => slab_min + f + 1,
            .neg_y => slab_min + f,
            .pos_z => slab_min + f + 1,
            .neg_z => slab_min + f,
        };

        // Face is visible (simple dot product)
        if (switch (kind) {
            .pos_x => cam_axis > axis_world_coord + eps,
            .neg_x => cam_axis < axis_world_coord - eps,
            .pos_y => cam_axis > axis_world_coord + eps,
            .neg_y => cam_axis < axis_world_coord - eps,
            .pos_z => cam_axis > axis_world_coord + eps,
            .neg_z => cam_axis < axis_world_coord - eps,
        }) emitRenderQuad(quad);
    }
}

pub fn generatePrimitivesFromChunk(chunk: *Chunk, camera_pos: F3) void {
    const min = chunk.world_min;
    const max = chunk.world_max;
    const pos = camera_pos;

    emitBucket(chunk.mesh.pos_x_faces.items[0..], .pos_x, pos[0], min[0], max[0]);
    emitBucket(chunk.mesh.pos_y_faces.items[0..], .pos_y, pos[1], min[1], max[1]);
    emitBucket(chunk.mesh.pos_z_faces.items[0..], .pos_z, pos[2], min[2], max[2]);
    emitBucket(chunk.mesh.neg_x_faces.items[0..], .neg_x, pos[0], min[0], max[0]);
    emitBucket(chunk.mesh.neg_y_faces.items[0..], .neg_y, pos[1], min[1], max[1]);
    emitBucket(chunk.mesh.neg_z_faces.items[0..], .neg_z, pos[2], min[2], max[2]);
}
