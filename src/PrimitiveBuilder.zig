const std = @import("std");
const main = @import("main.zig");
const types = @import("types.zig");
const mat = @import("math/matrix.zig");
const constants = @import("constants.zig");
const chunk_mod = @import("world/chunk.zig");

const F3 = types.F3;
const F4 = types.F4;
const UV = types.UV;
const FX2 = types.FX2;
const Face = types.Face;
const BlockId = types.BlockId;
const WorldVertex = types.WorldVertex;
const ChunkSlot = chunk_mod.ChunkSlot;
const Mat4f = @import("math/matrix.zig").Mat4f;
const World = @import("world/World.zig").World;
const PlaneKind = @import("mesh/Mesh.zig").PlaneKind;
const RenderQuad = @import("mesh/Mesh.zig").RenderQuad;
const FramebufferConfig = @import("EngineConfig.zig").EngineConfig.FramebufferConfig;

const TEX_SIZE = constants.TEX_SIZE;
const CHUNK_SIZE = constants.CHUNK_SIZE;
const SUBPIXEL_SCALE = constants.SUBPIXEL_SCALE;
const SUBPIXEL_MASK = (1 << constants.SUBPIXEL_BITS) - 1;

const AtomicUsize = std.atomic.Value(usize);

const BATCH_SIZE = 16;

const eps: f32 = 0.0001;

const plane_kind_to_face_map = [_]Face{
    .back, // neg_z = 0
    .front, // pos_z = 1
    .left, // neg_x = 2
    .right, // pos_x = 3
    .bottom, // neg_y = 4
    .top, // pos_y = 5
};

// In order to keep front to back rendering, we need a per-chunk segment table
const ChunkBuildSegment = struct {
    worker_id: u16 = 0,
    valid: bool = false, // move valid out of this struct

    vertex_start: u32 = 0,
    vertex_count: u32 = 0,

    primitive_start: u32 = 0,
    primitive_count: u32 = 0,

    final_vertex_start: u32 = 0,
    final_primitive_start: u32 = 0,
};

const VisibleChunk = struct {
    chunk_i: usize,
    slot: *const ChunkSlot,
};

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

inline fn isChunkInFrustum(chunk: *const ChunkSlot, planes: *const [5]F4) bool {
    const world_max: F3 = @floatFromInt(chunk.world_max);
    const world_min: F3 = @floatFromInt(chunk.world_min);

    var inside = true;

    for (planes) |plane| {
        const point = F4{
            if (plane[0] >= 0) world_max[0] else world_min[0],
            if (plane[1] >= 0) world_max[1] else world_min[1],
            if (plane[2] >= 0) world_max[2] else world_min[2],
            1,
        };

        const dist = @reduce(.Add, point * plane);
        if (dist < 0) {
            inside = false;
            break;
        }
    }

    return inside;
}

fn buildingWorker(
    worker_id: usize,
    next: *AtomicUsize,
    planes: *const [5]F4,
    chunks: []const *const ChunkSlot,
    allocator: std.mem.Allocator,
    primitive_builder: *PrimitiveBuilder,
    camera_pos: F3,
    combined_mat: Mat4f,
) void {
    var prims = &primitive_builder.workers_frame_primitives[worker_id];
    var mats = &primitive_builder.workers_frame_materials[worker_id];
    var verts = &primitive_builder.workers_frame_vertices[worker_id];

    while (true) {
        const chunk_base = next.fetchAdd(BATCH_SIZE, .monotonic);
        if (chunk_base >= chunks.len) break;

        var count: usize = 0;
        var visible_chunks: [BATCH_SIZE]VisibleChunk = undefined;

        // Find visible chunks

        const chunk_count = @min(BATCH_SIZE, chunks.len - chunk_base);

        for (0..chunk_count) |incr| {
            const chunk_i = chunk_base + incr;
            const chunk = chunks[chunk_i];

            if (isChunkInFrustum(chunk, planes) and chunk.mesh != null) {
                visible_chunks[count] = .{
                    .chunk_i = chunk_i,
                    .slot = chunk,
                };
                count += 1;
            }
        }

        // Ensure total capacity of ArrayLists

        const max_vertices_per_clipped_primitive = 9;
        var primitives_sum: usize = 0;
        for (0..count) |i| {
            const mesh = visible_chunks[i].slot.mesh.?;
            primitives_sum +=
                mesh.neg_x_faces.items.len +
                mesh.pos_x_faces.items.len +
                mesh.neg_y_faces.items.len +
                mesh.pos_y_faces.items.len +
                mesh.neg_z_faces.items.len +
                mesh.pos_z_faces.items.len;
        }

        prims.ensureUnusedCapacity(allocator, primitives_sum) catch @panic("OOM");
        mats.ensureUnusedCapacity(allocator, primitives_sum) catch @panic("OOM");
        verts.ensureUnusedCapacity(
            allocator,
            primitives_sum * max_vertices_per_clipped_primitive,
        ) catch @panic("OOM");

        // Generate primitives for all chunks

        for (0..count) |i| {
            const vc = visible_chunks[i];
            const chunk = vc.slot;

            const v_start: u32 =
                @intCast(primitive_builder.workers_frame_vertices[worker_id].items.len);
            const p_start: u32 =
                @intCast(primitive_builder.workers_frame_primitives[worker_id].items.len);

            generatePrimitivesFromChunk(
                primitive_builder,
                worker_id,
                chunk,
                camera_pos,
                combined_mat,
            ) catch @panic("Failed to generate primitives from chunk");

            const v_end: u32 =
                @intCast(primitive_builder.workers_frame_vertices[worker_id].items.len);
            const p_end: u32 =
                @intCast(primitive_builder.workers_frame_primitives[worker_id].items.len);

            primitive_builder.chunk_segments.items[vc.chunk_i] = .{
                .worker_id = @intCast(worker_id),
                .valid = true,

                .vertex_start = v_start,
                .vertex_count = v_end - v_start,

                .primitive_start = p_start,
                .primitive_count = p_end - p_start,
            };
        }
    }
}

pub const PrimitiveBuilder = struct {
    cpu_count: usize,

    fb_width: usize,
    fb_height: usize,
    tile_dimensions: usize,
    tiles_count_w: usize,
    tiles_count_h: usize,

    workers_frame_primitives: []std.ArrayList(PrimitiveRef),
    workers_frame_materials: []std.ArrayList(MaterialRef),
    workers_frame_vertices: []std.ArrayList(ProjectedVertex),

    frame_primitives: std.ArrayList(PrimitiveRef),
    frame_materials: std.ArrayList(MaterialRef),
    frame_vertices: std.ArrayList(ProjectedVertex),

    chunk_segments: std.ArrayList(ChunkBuildSegment),

    planes: [5]F4 = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        conf: FramebufferConfig,
    ) !PrimitiveBuilder {
        const tiles_count_w = try std.math.divCeil(usize, conf.width, conf.tile_dimensions);
        const tiles_count_h = try std.math.divCeil(usize, conf.height, conf.tile_dimensions);

        const cpu_count = try std.Thread.getCpuCount();

        const workers_frame_primitives =
            try allocator.alloc(std.ArrayList(PrimitiveRef), cpu_count);
        const workers_frame_materials =
            try allocator.alloc(std.ArrayList(MaterialRef), cpu_count);
        const workers_frame_vertices =
            try allocator.alloc(std.ArrayList(ProjectedVertex), cpu_count);

        for (0..cpu_count) |i| {
            workers_frame_primitives[i] = .empty;
            workers_frame_materials[i] = .empty;
            workers_frame_vertices[i] = .empty;
        }

        return .{
            .cpu_count = cpu_count,

            .fb_width = conf.width,
            .fb_height = conf.height,
            .tile_dimensions = conf.tile_dimensions,

            .tiles_count_w = tiles_count_w,
            .tiles_count_h = tiles_count_h,

            .workers_frame_primitives = workers_frame_primitives,
            .workers_frame_materials = workers_frame_materials,
            .workers_frame_vertices = workers_frame_vertices,

            .frame_primitives = .empty,
            .frame_materials = .empty,
            .frame_vertices = .empty,

            .chunk_segments = .empty,
        };
    }

    pub fn deinit(self: *PrimitiveBuilder, allocator: std.mem.Allocator) void {
        for (0..self.cpu_count) |i| {
            self.workers_frame_primitives[i].deinit(allocator);
            self.workers_frame_materials[i].deinit(allocator);
            self.workers_frame_vertices[i].deinit(allocator);
        }
        allocator.free(self.workers_frame_primitives);
        allocator.free(self.workers_frame_materials);
        allocator.free(self.workers_frame_vertices);

        self.frame_primitives.deinit(allocator);
        self.frame_materials.deinit(allocator);
        self.frame_vertices.deinit(allocator);

        self.chunk_segments.deinit(allocator);
    }

    inline fn floorFixed(x: i32) i32 {
        return @intCast(@divFloor(@as(i64, x), SUBPIXEL_SCALE));
    }

    inline fn ceilFixed(x: i32) i32 {
        const xi: i64 = x;
        return @intCast(-@divFloor(-xi, SUBPIXEL_SCALE));
    }

    inline fn ndcToScreenFixedPoint(self: *PrimitiveBuilder, x_ndc: f32, y_ndc: f32) FX2 {
        const fw: f32 = @floatFromInt(self.fb_width);
        const fh: f32 = @floatFromInt(self.fb_height);

        const sx = (x_ndc + 1.0) * 0.5 * fw;
        const sy = (1.0 - (y_ndc + 1.0) * 0.5) * fh;

        return .{
            @intFromFloat(@floor(sx * SUBPIXEL_SCALE)),
            @intFromFloat(@floor(sy * SUBPIXEL_SCALE)),
        };
    }

    inline fn clampTileRange(
        self: *const PrimitiveBuilder,
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

    inline fn emitQuad(
        self: *PrimitiveBuilder,
        worker_id: usize,
        verts_coord: *const [4]F4,
        verts_uv: *const [4]UV,
        id: BlockId,
        face: Face,
    ) void {
        var vertices: [4]ProjectedVertex = undefined;

        var rec_w = 1.0 / verts_coord[0][3];
        vertices[0].q = rec_w;
        var v = verts_coord[0] * @as(F4, @splat(rec_w));

        var p = self.ndcToScreenFixedPoint(v[0], v[1]);

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

            p = self.ndcToScreenFixedPoint(v[0], v[1]);

            min_x = @min(min_x, p[0]);
            max_x = @max(max_x, p[0]);
            min_y = @min(min_y, p[1]);
            max_y = @max(max_y, p[1]);

            vertices[i].xy = p;
            vertices[i].uv = verts_uv[i];
        }

        const tr = self.clampTileRange(min_x, max_x, min_y, max_y);

        const base: u32 = @intCast(self.workers_frame_vertices[worker_id].items.len);
        self.workers_frame_vertices[worker_id].appendSliceAssumeCapacity(&vertices);
        self.workers_frame_primitives[worker_id].appendAssumeCapacity(.{
            .base_vertex = base,
            .vertex_count = 4,
            .min_tx = tr.min_tx,
            .max_tx = tr.max_tx,
            .min_ty = tr.min_ty,
            .max_ty = tr.max_ty,
        });
        self.workers_frame_materials[worker_id].appendAssumeCapacity(.{
            .id = id,
            .face = face,
        });
    }

    inline fn emitPolygon(
        self: *PrimitiveBuilder,
        worker_id: usize,
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

        var p = self.ndcToScreenFixedPoint(v[0], v[1]);

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

            p = self.ndcToScreenFixedPoint(v[0], v[1]);

            min_x = @min(min_x, p[0]);
            max_x = @max(max_x, p[0]);
            min_y = @min(min_y, p[1]);
            max_y = @max(max_y, p[1]);

            vertices[i].xy = p;
            vertices[i].uv = polygon.verts[i].uv;
        }

        const tr = self.clampTileRange(min_x, max_x, min_y, max_y);

        const base: u32 = @intCast(self.workers_frame_vertices[worker_id].items.len);
        self.workers_frame_vertices[worker_id].appendSliceAssumeCapacity(vertices[0..len]);
        self.workers_frame_primitives[worker_id].appendAssumeCapacity(.{
            .base_vertex = base,
            .vertex_count = @intCast(len),
            .min_tx = tr.min_tx,
            .max_tx = tr.max_tx,
            .min_ty = tr.min_ty,
            .max_ty = tr.max_ty,
        });
        self.workers_frame_materials[worker_id].appendAssumeCapacity(.{
            .id = id,
            .face = face,
        });
    }

    pub fn buildPrimitives(
        self: *PrimitiveBuilder,
        chunks: []const *const ChunkSlot,
        camera_pos: F3,
        combined_mat: Mat4f,
        allocator: std.mem.Allocator,
        group: *std.Io.Group,
        io: std.Io,
    ) !void {
        self.frame_primitives.clearRetainingCapacity();
        self.frame_materials.clearRetainingCapacity();
        self.frame_vertices.clearRetainingCapacity();

        for (0..self.cpu_count) |i| {
            self.workers_frame_primitives[i].clearRetainingCapacity();
            self.workers_frame_materials[i].clearRetainingCapacity();
            self.workers_frame_vertices[i].clearRetainingCapacity();
        }

        try self.chunk_segments.ensureTotalCapacity(allocator, chunks.len);
        self.chunk_segments.clearRetainingCapacity();
        self.chunk_segments.appendNTimesAssumeCapacity(.{}, chunks.len);

        const planes = [5]F4{
            combined_mat.r[3] + combined_mat.r[0], // left
            combined_mat.r[3] - combined_mat.r[0], // right
            combined_mat.r[3] + combined_mat.r[1], // bottom
            combined_mat.r[3] - combined_mat.r[1], // top
            combined_mat.r[2], // near
        };

        var next = AtomicUsize.init(0);

        for (0..self.cpu_count) |i| {
            group.async(io, buildingWorker, .{
                i,
                &next,
                &planes,
                chunks,
                allocator,
                self,
                camera_pos,
                combined_mat,
            });
        }

        try group.await(io);

        // Understand this code, too tired today

        var total_length_primitives: u32 = 0;
        var total_length_vertices: u32 = 0;

        for (self.chunk_segments.items) |*seg| {
            if (!seg.valid) continue;

            seg.final_vertex_start = total_length_vertices;
            seg.final_primitive_start = total_length_primitives;

            total_length_vertices += seg.vertex_count;
            total_length_primitives += seg.primitive_count;
        }

        try self.frame_primitives.ensureTotalCapacity(allocator, total_length_primitives);
        try self.frame_materials.ensureTotalCapacity(allocator, total_length_primitives);
        try self.frame_vertices.ensureTotalCapacity(allocator, total_length_vertices);

        self.frame_primitives.items.len = total_length_primitives;
        self.frame_materials.items.len = total_length_primitives;
        self.frame_vertices.items.len = total_length_vertices;

        for (self.chunk_segments.items) |seg| {
            if (!seg.valid or seg.primitive_count == 0) continue;

            const worker_id: usize = seg.worker_id;

            const worker_vertices = self.workers_frame_vertices[worker_id].items;
            const worker_prims = self.workers_frame_primitives[worker_id].items;
            const worker_mats = self.workers_frame_materials[worker_id].items;

            const src_v0: usize = seg.vertex_start;
            const src_v1: usize = src_v0 + seg.vertex_count;

            const src_p0: usize = seg.primitive_start;
            const src_p1: usize = src_p0 + seg.primitive_count;

            const dst_v0: usize = seg.final_vertex_start;
            const dst_v1: usize = dst_v0 + seg.vertex_count;

            const dst_p0: usize = seg.final_primitive_start;
            const dst_p1: usize = dst_p0 + seg.primitive_count;

            @memcpy(
                self.frame_vertices.items[dst_v0..dst_v1],
                worker_vertices[src_v0..src_v1],
            );

            @memcpy(
                self.frame_materials.items[dst_p0..dst_p1],
                worker_mats[src_p0..src_p1],
            );

            for (worker_prims[src_p0..src_p1], 0..) |p, i| {
                var fixed = p;

                fixed.base_vertex =
                    p.base_vertex -
                    @as(u32, @intCast(seg.vertex_start)) +
                    seg.final_vertex_start;

                self.frame_primitives.items[dst_p0 + i] = fixed;
            }
        }
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
    primitive_builder: *PrimitiveBuilder,
    worker_id: usize,
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
        primitive_builder.emitQuad(worker_id, &verts_coord, &verts_uv, rq.voxel.id, face);
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

    primitive_builder.emitPolygon(worker_id, &clipped_polygon, rq.voxel.id, face);
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
    primitive_builder: *PrimitiveBuilder,
    worker_id: usize,
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
            primitive_builder,
            worker_id,
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

                try emitRenderQuad(kind, quad, chunk_min, combined_mat, primitive_builder, worker_id);
            }
        } else {
            if (cam_axis < axis_world_coord - eps) {
                if (main.ENABLE_DEBUG_OVERLAY) main.debug_overlay.triangles_after_bucket_cull += 2;

                try emitRenderQuad(kind, quad, chunk_min, combined_mat, primitive_builder, worker_id);
            }
        }
    }
}

pub fn generatePrimitivesFromChunk(
    primitive_builder: *PrimitiveBuilder,
    worker_id: usize,
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

    try emitBucket(.pos_x, mesh.pos_x_faces.items, pos[0], min[0], max[0], min, combined_mat, primitive_builder, worker_id);
    try emitBucket(.pos_y, mesh.pos_y_faces.items, pos[1], min[1], max[1], min, combined_mat, primitive_builder, worker_id);
    try emitBucket(.pos_z, mesh.pos_z_faces.items, pos[2], min[2], max[2], min, combined_mat, primitive_builder, worker_id);
    try emitBucket(.neg_x, mesh.neg_x_faces.items, pos[0], min[0], max[0], min, combined_mat, primitive_builder, worker_id);
    try emitBucket(.neg_y, mesh.neg_y_faces.items, pos[1], min[1], max[1], min, combined_mat, primitive_builder, worker_id);
    try emitBucket(.neg_z, mesh.neg_z_faces.items, pos[2], min[2], max[2], min, combined_mat, primitive_builder, worker_id);
}
