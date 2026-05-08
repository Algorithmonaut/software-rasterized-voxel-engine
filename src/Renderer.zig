const std = @import("std");
const main = @import("main.zig");
const types = @import("types.zig");
const chunk = @import("world/chunk.zig");
const constants = @import("constants.zig");

const Mat4f = @import("math/matrix.zig").Mat4f;
const PlaneKind = @import("mesh/Mesh.zig").PlaneKind;
const ChunkSlot = chunk.ChunkSlot;
const RenderQuad = @import("mesh/Mesh.zig").RenderQuad;
const FramebufferConfig = @import("EngineConfig.zig").EngineConfig.FramebufferConfig;

const UV = types.UV;
const F3 = types.F3;
const F4 = types.F4;
const FX2 = types.FX2;
const Face = types.Face;
const BlockId = types.BlockId;
const WorldVertex = types.WorldVertex;

const TEX_SIZE = constants.TEX_SIZE;
const CHUNK_SIZE = constants.CHUNK_SIZE;
const SUBPIXEL_SCALE = constants.SUBPIXEL_SCALE;
const SUBPIXEL_MASK = (1 << constants.SUBPIXEL_BITS) - 1;

// TODO: Centralize this

const eps: f32 = 0.0001;

const plane_kind_to_face_map = [_]Face{
    .back, // neg_z = 0
    .front, // pos_z = 1
    .left, // neg_x = 2
    .right, // pos_x = 3
    .bottom, // neg_y = 4
    .top, // pos_y = 5
};

pub const Renderer = struct {
    pub const ProjectedVertex = struct { xy: FX2, q: f32, uv: UV };
    pub const MaterialRef = struct { id: BlockId, face: Face };
    pub const PrimitiveRef = struct {
        base_vertex: u32 = undefined,
        vertex_count: u8 = undefined,
        min_tx: u16 = 0,
        max_tx: u16 = std.math.maxInt(u16),
        min_ty: u16 = 0,
        max_ty: u16 = std.math.maxInt(u16),
    };

    frame_primitives: std.ArrayList(PrimitiveRef),
    frame_materials: std.ArrayList(MaterialRef),
    frame_vertices: std.ArrayList(ProjectedVertex),

    fb_width: usize,
    fb_height: usize,
    tile_dimensions: usize,
    tiles_count_w: usize,
    tiles_count_h: usize,

    planes: [5]F4 = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        conf: FramebufferConfig,
        view_distance: f32,
    ) !Renderer {
        _ = view_distance;

        const tiles_count_w = try std.math.divCeil(usize, conf.width, conf.tile_dimensions);
        const tiles_count_h = try std.math.divCeil(usize, conf.height, conf.tile_dimensions);

        return .{
            // TODO: I presume that these are good estimates, but please investigate
            .frame_primitives = try std.ArrayList(PrimitiveRef).initCapacity(allocator, 70_000),
            .frame_materials = try std.ArrayList(MaterialRef).initCapacity(allocator, 70_000),
            .frame_vertices = try std.ArrayList(ProjectedVertex).initCapacity(allocator, 280_000),

            .fb_width = conf.width,
            .fb_height = conf.height,
            .tile_dimensions = conf.tile_dimensions,

            .tiles_count_w = tiles_count_w,
            .tiles_count_h = tiles_count_h,
        };
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        self.frame_primitives.deinit(allocator);
        self.frame_materials.deinit(allocator);
        self.frame_vertices.deinit(allocator);
        self.chunk_entries.deinit(allocator);
    }

    pub fn beginFrame(self: *Renderer) void {
        self.frame_primitives.clearRetainingCapacity();
        self.frame_materials.clearRetainingCapacity();
        self.frame_vertices.clearRetainingCapacity();
    }

    inline fn ndcToScreenFixedPoint(
        x_ndc: f32,
        y_ndc: f32,
        fb_width: usize,
        fb_height: usize,
    ) FX2 {
        const fw: f32 = @floatFromInt(fb_width);
        const fh: f32 = @floatFromInt(fb_height);

        const sx = (x_ndc + 1.0) * 0.5 * fw;
        const sy = (1.0 - (y_ndc + 1.0) * 0.5) * fh;

        return .{
            @intFromFloat(@floor(sx * SUBPIXEL_SCALE)),
            @intFromFloat(@floor(sy * SUBPIXEL_SCALE)),
        };
    }

    inline fn floorFixed(x: i32) i32 {
        return @intCast(@divFloor(@as(i64, x), SUBPIXEL_SCALE));
    }

    inline fn ceilFixed(x: i32) i32 {
        const xi: i64 = x;
        return @intCast(-@divFloor(-xi, SUBPIXEL_SCALE));
    }

    // TODO: Understand this code
    inline fn clampTileRange(
        self: *const Renderer,
        min_x_fx: i32,
        max_x_fx: i32,
        min_y_fx: i32,
        max_y_fx: i32,
    ) struct { min_tx: u16, max_tx: u16, min_ty: u16, max_ty: u16 } {
        const tile_dim: i32 = @intCast(self.tile_dimensions);
        const tile_w: i32 = @intCast(self.tiles_count_w);
        const tile_h: i32 = @intCast(self.tiles_count_h);

        // Convert fixed-point screen bbox to pixel bbox
        const px_min_x = floorFixed(min_x_fx);
        const px_max_x = ceilFixed(max_x_fx);
        const px_min_y = floorFixed(min_y_fx);
        const px_max_y = ceilFixed(max_y_fx);

        // Convert to tile coords in signed space
        const raw_min_tx = @divFloor(px_min_x, tile_dim);
        const raw_max_tx = std.math.divCeil(i32, px_max_x, tile_dim) catch unreachable;
        const raw_min_ty = @divFloor(px_min_y, tile_dim);
        const raw_max_ty = std.math.divCeil(i32, px_max_y, tile_dim) catch unreachable;

        // Clamp to tile grid, max is exclusive
        const min_tx = std.math.clamp(raw_min_tx, 0, tile_w);
        const max_tx = std.math.clamp(raw_max_tx, 0, tile_w);
        const min_ty = std.math.clamp(raw_min_ty, 0, tile_h);
        const max_ty = std.math.clamp(raw_max_ty, 0, tile_h);

        return .{
            .min_tx = @intCast(min_tx),
            .max_tx = @intCast(max_tx),
            .min_ty = @intCast(min_ty),
            .max_ty = @intCast(max_ty),
        };
    }

    /// No need to do backface culling anymore
    inline fn emitQuad(
        self: *Renderer,
        verts_coord: *const [4]F4,
        verts_uv: *const [4]UV,
        id: BlockId,
        face: Face,
    ) void {
        var vertices: [4]ProjectedVertex = undefined;

        var rec_w = 1.0 / verts_coord[0][3];
        vertices[0].q = rec_w;
        var v = verts_coord[0] * @as(F4, @splat(rec_w));

        var p = ndcToScreenFixedPoint(
            v[0],
            v[1],
            self.fb_width,
            self.fb_height,
        );

        var min_x = p[0];
        var max_x = p[0];
        var min_y = p[1];
        var max_y = p[1];

        vertices[0].xy = p;
        vertices[0].uv = verts_uv[0];

        inline for (1..4) |i| {
            rec_w = 1.0 / verts_coord[i][3];
            vertices[i].q = rec_w;
            v = verts_coord[i] * @as(F4, @splat(rec_w));

            p = ndcToScreenFixedPoint(
                v[0],
                v[1],
                self.fb_width,
                self.fb_height,
            );

            min_x = @min(min_x, p[0]);
            max_x = @max(max_x, p[0]);
            min_y = @min(min_y, p[1]);
            max_y = @max(max_y, p[1]);

            vertices[i].xy = p;
            vertices[i].uv = verts_uv[i];
        }

        const tr = self.clampTileRange(min_x, max_x, min_y, max_y);

        const prim_i = self.frame_primitives.items.len;
        const old_vert_len = self.frame_vertices.items.len;
        const old_prim_len = self.frame_primitives.items.len;
        const old_mat_len = self.frame_materials.items.len;

        std.debug.assert(old_prim_len == old_mat_len);

        const base: u32 = @intCast(self.frame_vertices.items.len);
        self.frame_vertices.appendSliceAssumeCapacity(&vertices);
        self.frame_primitives.appendAssumeCapacity(.{
            .base_vertex = base,
            .vertex_count = 4,
            .min_tx = tr.min_tx,
            .max_tx = tr.max_tx,
            .min_ty = tr.min_ty,
            .max_ty = tr.max_ty,
        });
        self.frame_materials.appendAssumeCapacity(.{
            .id = id,
            .face = face,
        });

        if (self.frame_vertices.items.len != old_vert_len + 4)
            std.debug.panic(
                "emitQuad bad append: prim_i={}, old_vert_len={}, new_vert_len={}",
                .{ prim_i, old_vert_len, self.frame_vertices.items.len },
            );

        if (self.frame_primitives.items[prim_i].base_vertex != base)
            std.debug.panic(
                "emitQuad bad base: prim_i={}, expected={}, got={}",
                .{ prim_i, base, self.frame_primitives.items[prim_i].base_vertex },
            );
    }

    inline fn emitPolygon(
        self: *Renderer,
        polygon: *ClippedPolygon,
        id: BlockId,
        face: Face,
    ) void {
        const len = polygon.len;

        if (len < 3) std.debug.panic("Less than 3 vertices", .{});
        if (len > 9) std.debug.panic("More than 3 vertices", .{});

        var vertices: [9]ProjectedVertex = undefined;

        var rec_w = 1.0 / polygon.verts[0].pos[3];
        vertices[0].q = rec_w;
        var v = polygon.verts[0].pos * @as(F4, @splat(rec_w));

        var p = ndcToScreenFixedPoint(
            v[0],
            v[1],
            self.fb_width,
            self.fb_height,
        );

        var min_x = p[0];
        var max_x = p[0];
        var min_y = p[1];
        var max_y = p[1];

        vertices[0].xy = p;
        vertices[0].uv = polygon.verts[0].uv;

        for (1..len) |i| {
            rec_w = 1.0 / polygon.verts[i].pos[3];
            vertices[i].q = rec_w;
            v = polygon.verts[i].pos * @as(F4, @splat(rec_w));

            p = ndcToScreenFixedPoint(
                v[0],
                v[1],
                self.fb_width,
                self.fb_height,
            );

            min_x = @min(min_x, p[0]);
            max_x = @max(max_x, p[0]);
            min_y = @min(min_y, p[1]);
            max_y = @max(max_y, p[1]);

            vertices[i].xy = p;
            vertices[i].uv = polygon.verts[i].uv;
        }

        const tr = self.clampTileRange(min_x, max_x, min_y, max_y);

        const prim_i = self.frame_primitives.items.len;
        const old_vert_len = self.frame_vertices.items.len;
        const old_prim_len = self.frame_primitives.items.len;
        const old_mat_len = self.frame_materials.items.len;

        std.debug.assert(old_prim_len == old_mat_len);

        const base: u32 = @intCast(self.frame_vertices.items.len);
        self.frame_vertices.appendSliceAssumeCapacity(vertices[0..len]);
        self.frame_primitives.appendAssumeCapacity(.{
            .base_vertex = base,
            .vertex_count = @intCast(len),
            .min_tx = tr.min_tx,
            .max_tx = tr.max_tx,
            .min_ty = tr.min_ty,
            .max_ty = tr.max_ty,
        });
        self.frame_materials.appendAssumeCapacity(.{
            .id = id,
            .face = face,
        });

        if (self.frame_vertices.items.len != old_vert_len + len)
            std.debug.panic(
                "emitPolygon bad append: prim_i={}, len={}, old_vert_len={}, new_vert_len={}",
                .{ prim_i, len, old_vert_len, self.frame_vertices.items.len },
            );

        if (self.frame_primitives.items[prim_i].base_vertex != base)
            std.debug.panic(
                "emitPolygon bad base: prim_i={}, expected={}, got={}",
                .{ prim_i, base, self.frame_primitives.items[prim_i].base_vertex },
            );
    }
};

//// PRIMITIVE BUILDING & CULLING //////////////////////////////////////////////
/// 2 places => at most 2 new vertices.
/// But to do that, at least one old vertex must be removed.
/// We clip against 5 planes, and start with a quad: 4 + 5 = 9 vertices.
const ClippedPolygon = struct {
    verts: [9]WorldVertex,
    len: usize = 0,

    inline fn add(self: *ClippedPolygon, vert: WorldVertex) void {
        self.verts[self.len] = vert;
        self.len += 1;
    }
};

inline fn clipCode(v: F4) u8 {
    var code: u8 = 0; // bitfield
    if (v[0] < -v[3]) code |= 1 << 0; // left
    if (v[0] > v[3]) code |= 1 << 1; // right
    if (v[1] < -v[3]) code |= 1 << 2; // bottom
    if (v[1] > v[3]) code |= 1 << 3; // top
    if (v[2] < 0) code |= 1 << 4; // near
    return code;
}

const Plane = enum(u8) {
    LEFT = 1,
    RIGHT = 2,
    BOTTOM = 4,
    TOP = 8,
    NEAR = 16,
};

inline fn planeDistance(vert: WorldVertex, plane: Plane) f32 {
    switch (plane) {
        Plane.LEFT => return vert.pos[0] + vert.pos[3],
        Plane.RIGHT => return -vert.pos[0] + vert.pos[3],
        Plane.BOTTOM => return vert.pos[1] + vert.pos[3],
        Plane.TOP => return -vert.pos[1] + vert.pos[3],
        Plane.NEAR => return vert.pos[2],
    }
}

inline fn isInside(vert: WorldVertex, plane: Plane) bool {
    return planeDistance(vert, plane) >= 0;
}

inline fn intersectPlane(
    v0: WorldVertex,
    v1: WorldVertex,
    plane: Plane,
) WorldVertex {
    const fa = planeDistance(v0, plane);
    const fb = planeDistance(v1, plane);
    const t = fa / (fa - fb);

    return .{
        .pos = v0.pos + @as(F4, @splat(t)) * (v1.pos - v0.pos),
        .uv = v0.uv + @as(UV, @splat(t)) * (v1.uv - v0.uv),
    };
}

fn clipPolygonAgainstPlane(
    polygon: ClippedPolygon,
    plane: Plane,
) ClippedPolygon {
    if (polygon.len == 0) return .{
        .verts = undefined,
        .len = 0,
    };

    var output_polygon = ClippedPolygon{
        .verts = undefined,
        .len = 0,
    };

    for (0..polygon.len) |i| {
        const v0 = polygon.verts[i];
        const v1 = polygon.verts[(i + 1) % polygon.len];

        if (isInside(v0, plane)) {
            if (isInside(v1, plane))
                output_polygon.add(v1)
            else
                output_polygon.add(intersectPlane(v0, v1, plane));
        } else {
            if (isInside(v1, plane)) {
                output_polygon.add(intersectPlane(v0, v1, plane));
                output_polygon.add(v1);
            }
        }
    }

    return output_polygon;
}

fn emitRenderQuad(
    comptime kind: PlaneKind,
    rq: RenderQuad,
    chunk_min: F3,
    combined_mat: Mat4f,
    renderer: *Renderer,
) !void {
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
            .{ fx + fixed + 1.0, fy + row0, fz + col0, 1.0 },
            .{ fx + fixed + 1.0, fy + row0 + h, fz + col0, 1.0 },
            .{ fx + fixed + 1.0, fy + row0 + h, fz + col0 + w, 1.0 },
            .{ fx + fixed + 1.0, fy + row0, fz + col0 + w, 1.0 },
        },
        .neg_x => .{
            .{ fx + fixed, fy + row0, fz + col0, 1.0 },
            .{ fx + fixed, fy + row0, fz + col0 + w, 1.0 },
            .{ fx + fixed, fy + row0 + h, fz + col0 + w, 1.0 },
            .{ fx + fixed, fy + row0 + h, fz + col0, 1.0 },
        },

        // y = const, x=row, z=col
        .pos_y => .{
            .{ fx + row0, fy + fixed + 1.0, fz + col0, 1.0 },
            .{ fx + row0, fy + fixed + 1.0, fz + col0 + w, 1.0 },
            .{ fx + row0 + h, fy + fixed + 1.0, fz + col0 + w, 1.0 },
            .{ fx + row0 + h, fy + fixed + 1.0, fz + col0, 1.0 },
        },
        .neg_y => .{
            .{ fx + row0, fy + fixed, fz + col0, 1.0 },
            .{ fx + row0 + h, fy + fixed, fz + col0, 1.0 },
            .{ fx + row0 + h, fy + fixed, fz + col0 + w, 1.0 },
            .{ fx + row0, fy + fixed, fz + col0 + w, 1.0 },
        },

        // z = const, x=row, y=col
        .pos_z => .{
            .{ fx + row0, fy + col0, fz + fixed + 1.0, 1.0 },
            .{ fx + row0 + h, fy + col0, fz + fixed + 1.0, 1.0 },
            .{ fx + row0 + h, fy + col0 + w, fz + fixed + 1.0, 1.0 },
            .{ fx + row0, fy + col0 + w, fz + fixed + 1.0, 1.0 },
        },
        .neg_z => .{
            .{ fx + row0, fy + col0, fz + fixed, 1.0 },
            .{ fx + row0, fy + col0 + w, fz + fixed, 1.0 },
            .{ fx + row0 + h, fy + col0 + w, fz + fixed, 1.0 },
            .{ fx + row0 + h, fy + col0, fz + fixed, 1.0 },
        },
    };

    // World → raster
    verts_coord[0] = combined_mat.mulVec(verts_coord[0]);
    verts_coord[1] = combined_mat.mulVec(verts_coord[1]);
    verts_coord[2] = combined_mat.mulVec(verts_coord[2]);
    verts_coord[3] = combined_mat.mulVec(verts_coord[3]);

    const c0 = clipCode(verts_coord[0]);
    const c1 = clipCode(verts_coord[1]);
    const c2 = clipCode(verts_coord[2]);
    const c3 = clipCode(verts_coord[3]);

    const or_code = c0 | c1 | c2 | c3;
    const and_code = c0 & c1 & c2 & c3;

    if (and_code != 0) return; // quad trivially outside

    const verts_uv: [4]UV = switch (kind) {
        .pos_z => .{ .{ v_0, u_1 }, .{ v_1, u_1 }, .{ v_1, u_0 }, .{ v_0, u_0 } },
        .pos_x => .{ .{ u_1, v_1 }, .{ u_1, v_0 }, .{ u_0, v_0 }, .{ u_0, v_1 } },
        .neg_z => .{ .{ v_1, u_1 }, .{ v_1, u_0 }, .{ v_0, u_0 }, .{ v_0, u_1 } },
        .neg_x => .{ .{ u_0, v_1 }, .{ u_1, v_1 }, .{ u_1, v_0 }, .{ u_0, v_0 } },
        .pos_y => .{ .{ v_0, u_1 }, .{ v_0, u_0 }, .{ v_1, u_0 }, .{ v_1, u_1 } },
        .neg_y => .{ .{ v_0, u_0 }, .{ v_1, u_0 }, .{ v_1, u_1 }, .{ v_0, u_1 } },
    };

    const face = plane_kind_to_face_map[@intFromEnum(kind)];

    // Quad trivially inside
    if (or_code == 0) {
        renderer.emitQuad(&verts_coord, &verts_uv, rq.voxel.id, face);
        return;
    }

    var clipped_polygon: ClippedPolygon = undefined;
    clipped_polygon.verts[0].pos = verts_coord[0];
    clipped_polygon.verts[1].pos = verts_coord[1];
    clipped_polygon.verts[2].pos = verts_coord[2];
    clipped_polygon.verts[3].pos = verts_coord[3];
    clipped_polygon.verts[0].uv = verts_uv[0];
    clipped_polygon.verts[1].uv = verts_uv[1];
    clipped_polygon.verts[2].uv = verts_uv[2];
    clipped_polygon.verts[3].uv = verts_uv[3];
    clipped_polygon.len = 4;

    if ((or_code & @intFromEnum(Plane.LEFT)) != 0) {
        clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.LEFT);
        if (clipped_polygon.len < 3) return;
    }
    if ((or_code & @intFromEnum(Plane.RIGHT)) != 0) {
        clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.RIGHT);
        if (clipped_polygon.len < 3) return;
    }
    if ((or_code & @intFromEnum(Plane.BOTTOM)) != 0) {
        clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.BOTTOM);
        if (clipped_polygon.len < 3) return;
    }
    if ((or_code & @intFromEnum(Plane.TOP)) != 0) {
        clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.TOP);
        if (clipped_polygon.len < 3) return;
    }
    if ((or_code & @intFromEnum(Plane.NEAR)) != 0) {
        clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.NEAR);
        if (clipped_polygon.len < 3) return;
    }

    renderer.emitPolygon(&clipped_polygon, rq.voxel.id, face);
}

//// TRIVIAL, PLANE NORMAL BASED CULLING | AXIS BUCKET CULL ////////////////////

fn emitBucket(
    comptime kind: PlaneKind,
    quads: []const RenderQuad,
    cam_axis: f32,
    slab_min: f32,
    slab_max: f32,
    chunk_min: F3,
    combined_mat: Mat4f,
    renderer: *Renderer,
) !void {

    // POSITIVE AXIS (box is chunk):
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
        if (main.ENABLE_DEBUG_OVERLAY) main.debug_overlay.triangles_after_bucket_cull += quads.len * 2;

        for (quads) |quad| try emitRenderQuad(
            kind,
            quad,
            chunk_min,
            combined_mat,
            renderer,
        );
        return;
    }

    // No faces are visible
    if (cam_axis <= slab_min or cam_axis >= slab_max)
        return;

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
            if (cam_axis > axis_world_coord + eps) {
                if (main.ENABLE_DEBUG_OVERLAY) main.debug_overlay.triangles_after_bucket_cull += 2;

                try emitRenderQuad(
                    kind,
                    quad,
                    chunk_min,
                    combined_mat,
                    renderer,
                );
            }
        } else {
            if (cam_axis < axis_world_coord - eps) {
                if (main.ENABLE_DEBUG_OVERLAY) main.debug_overlay.triangles_after_bucket_cull += 2;

                try emitRenderQuad(
                    kind,
                    quad,
                    chunk_min,
                    combined_mat,
                    renderer,
                );
            }
        }
    }
}

pub fn generatePrimitivesFromChunk(
    renderer: *Renderer,
    slot: *const ChunkSlot,
    camera_pos: F3,
    combined_mat: Mat4f,
) !void {
    const mesh = slot.mesh orelse return;

    const min: F3 = @floatFromInt(slot.world_min);
    const max: F3 = @floatFromInt(slot.world_max);
    const pos = camera_pos;

    if (main.ENABLE_DEBUG_OVERLAY) main.debug_overlay.visible_chunk_triangles +=
        (mesh.pos_x_faces.items.len + mesh.neg_x_faces.items.len +
            mesh.pos_y_faces.items.len + mesh.neg_y_faces.items.len +
            mesh.pos_z_faces.items.len + mesh.neg_z_faces.items.len) * 2;

    try emitBucket(.pos_x, mesh.pos_x_faces.items, pos[0], min[0], max[0], min, combined_mat, renderer);
    try emitBucket(.pos_y, mesh.pos_y_faces.items, pos[1], min[1], max[1], min, combined_mat, renderer);
    try emitBucket(.pos_z, mesh.pos_z_faces.items, pos[2], min[2], max[2], min, combined_mat, renderer);
    try emitBucket(.neg_x, mesh.neg_x_faces.items, pos[0], min[0], max[0], min, combined_mat, renderer);
    try emitBucket(.neg_y, mesh.neg_y_faces.items, pos[1], min[1], max[1], min, combined_mat, renderer);
    try emitBucket(.neg_z, mesh.neg_z_faces.items, pos[2], min[2], max[2], min, combined_mat, renderer);
}
