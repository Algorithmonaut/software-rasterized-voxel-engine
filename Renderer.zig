const std = @import("std");

const Chunk = @import("world/Chunk.zig").Chunk;
const World = @import("world/World.zig").World;
const Camera = @import("game/Camera.zig").Camera;
const TerrainGenerator = @import("world/TerrainGenerator.zig").TerrainGenerator;

const RenderQuad = @import("mesh/Mesh.zig").RenderQuad;

const CHUNK_SIZE = @import("world/Chunk.zig").CHUNK_SIZE;
const TEX_SIZE = @import("Atlas.zig").TEX_SIZE;

const PlaneKind = @import("mesh/Mesh.zig").PlaneKind;

const types = @import("math/types.zig");
const F3 = types.Vec3f;
const F4 = types.Vec4f;
const I3 = types.Vec3i;
const WorldCoord = types.WorldCoord;
const ChunkCoord = types.ChunkCoord;

const Block = @import("world/Block.zig");
const WorldQuad = Block.WorldQuad;
const WorldVertex = Block.WorldVertex;
const Vertex = Block.Vertex;

const Vec2fx = types.Vec2fx;
const SUBPIXEL_BITS = types.SUBPIXEL_BITS;
const SUBPIXEL_SCALE = types.SUBPIXEL_SCALE;

const Mat4f = @import("math/matrix.zig").Mat4f;

const FramebufferConfig = @import("EngineConfig.zig").EngineConfig.FramebufferConfig;
const RasterTriangle = @import("triangle.zig").RasterTriangle;

// TODO: Centralize this
const UV = @Vector(2, f32);

const eps: f32 = 0.0001;

pub const Renderer = struct {
    const ChunkRenderEntry = struct {
        chunk: *Chunk,
        dist2: f32,
    };

    triangles: std.ArrayList(RasterTriangle),
    chunk_entries: std.ArrayList(ChunkRenderEntry),

    fb_width: usize,
    fb_height: usize,
    tile_dimensions: usize,

    planes: [5]F4 = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        conf: FramebufferConfig,
        view_distance: f32,
    ) !Renderer {
        _ = view_distance;

        return .{
            .triangles = try std.ArrayList(RasterTriangle).initCapacity(allocator, 1_000),
            .chunk_entries = try std.ArrayList(ChunkRenderEntry).initCapacity(allocator, 100),
            .fb_width = conf.width,
            .fb_height = conf.height,
            .tile_dimensions = conf.tile_dimensions,
        };
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        self.triangles.clearAndFree(allocator);
        self.chunk_entries.clearAndFree(allocator);
    }

    pub fn beginFrame(self: *Renderer) void {
        self.triangles.clearRetainingCapacity();
    }

    fn ndcToScreenFixedPoint(
        x_ndc: f32,
        y_ndc: f32,
        fb_width: usize,
        fb_height: usize,
    ) Vec2fx {
        const fw: f32 = @floatFromInt(fb_width);
        const fh: f32 = @floatFromInt(fb_height);

        const sx = (x_ndc + 1.0) * 0.5 * fw;
        const sy = (1.0 - (y_ndc + 1.0) * 0.5) * fh;

        return .{
            @intFromFloat(@floor(sx * SUBPIXEL_SCALE)),
            @intFromFloat(@floor(sy * SUBPIXEL_SCALE)),
        };
    }

    /// Use if the quad is trivially inside
    fn emitQuad(
        self: *Renderer,
        allocator: std.mem.Allocator,
        quad: WorldQuad,
    ) !void {
        // Backface culling (vertices are oriented CCW)
        // Only need to check a single triangle
        var v = [4]F4{ quad.v0.pos, quad.v1.pos, quad.v2.pos, quad.v3.pos };

        // Clip -> NDC
        var rec_ws: [4]f32 = undefined;
        for (0..v.len) |i| {
            const rec_w = 1.0 / v[i][3];
            rec_ws[i] = rec_w;
            v[i] *= @as(F4, @splat(rec_w));
        }

        // Backface culling
        const signed_area =
            (v[1][0] - v[0][0]) * (v[2][1] - v[0][1]) -
            (v[1][1] - v[0][1]) * (v[2][0] - v[0][0]);
        if (signed_area < 0) return;

        // NDC -> raster
        var raster_verts: [4]Vec2fx = undefined;
        for (0..v.len) |i| {
            const vert_pos = v[i];
            raster_verts[i] = ndcToScreenFixedPoint(
                vert_pos[0],
                vert_pos[1],
                self.fb_width,
                self.fb_height,
            );
        }

        // Still using fan triangulation
        try self.triangles.append(allocator, .{
            .v0 = raster_verts[0],
            .v1 = raster_verts[1],
            .v2 = raster_verts[2],
            .q0 = rec_ws[0],
            .q1 = rec_ws[1],
            .q2 = rec_ws[2],
            .uv0 = quad.v0.uv,
            .uv1 = quad.v1.uv,
            .uv2 = quad.v2.uv,

            .tex_u = quad.tex_u,
            .tex_v = quad.tex_v,
            .tex_tile_size = quad.tex_tile_size,
        });

        try self.triangles.append(allocator, .{
            .v0 = raster_verts[0],
            .v1 = raster_verts[2],
            .v2 = raster_verts[3],
            .q0 = rec_ws[0],
            .q1 = rec_ws[2],
            .q2 = rec_ws[3],
            .uv0 = quad.v0.uv,
            .uv1 = quad.v2.uv,
            .uv2 = quad.v3.uv,

            .tex_u = quad.tex_u,
            .tex_v = quad.tex_v,
            .tex_tile_size = quad.tex_tile_size,
        });
    }

    /// Use fan triangulation to emit triangles from the clipped convex polygon
    /// in clip space
    fn emitPolygonFan(
        self: *Renderer,
        allocator: std.mem.Allocator,
        polygon_in: ClippedPolygon,
        quad: WorldQuad,
    ) !void {
        if (polygon_in.len < 3) return; // triangle is degenerate

        var polygon = polygon_in;

        // Clip -> NDC
        var rec_ws: [9]f32 = undefined;
        for (0..polygon.len) |i| {
            const rec_w = 1.0 / polygon.verts[i].pos[3];
            rec_ws[i] = rec_w;
            polygon.verts[i].pos *= @as(F4, @splat(rec_w));
        }

        // Backface culling (vertices are oriented CCW)
        // Only need to check a single triangle
        {
            const v0 = polygon.verts[0].pos;
            const v1 = polygon.verts[1].pos;
            const v2 = polygon.verts[2].pos;
            const signed_area =
                (v1[0] - v0[0]) * (v2[1] - v0[1]) -
                (v1[1] - v0[1]) * (v2[0] - v0[0]);
            if (signed_area < 0) return;
        }

        // NDC -> raster
        var raster_verts: [9]Vec2fx = undefined;
        for (0..polygon.len) |i| {
            const vert_pos = polygon.verts[i].pos;
            raster_verts[i] = ndcToScreenFixedPoint(
                vert_pos[0],
                vert_pos[1],
                self.fb_width,
                self.fb_height,
            );
        }

        // Using fan triangulation, emit the raster triangles
        var i: usize = 1;
        while (i + 1 < polygon.len) : (i += 1) {
            try self.triangles.append(allocator, .{
                .v0 = raster_verts[0],
                .v1 = raster_verts[i],
                .v2 = raster_verts[i + 1],
                .q0 = rec_ws[0],
                .q1 = rec_ws[i],
                .q2 = rec_ws[i + 1],
                .uv0 = polygon.verts[0].uv,
                .uv1 = polygon.verts[i].uv,
                .uv2 = polygon.verts[i + 1].uv,

                .tex_u = quad.tex_u,
                .tex_v = quad.tex_v,
                .tex_tile_size = quad.tex_tile_size,
            });
        }
    }

    //// CHUNK RENDERING ///////////////////////////////////////////////////////

    pub fn computeFrustumPlanes(self: *Renderer, combined_mat: Mat4f) void {
        self.planes = .{
            combined_mat.r[3] + combined_mat.r[0], // left
            combined_mat.r[3] - combined_mat.r[0], // right
            combined_mat.r[3] + combined_mat.r[1], // bottom
            combined_mat.r[3] - combined_mat.r[1], // top
            combined_mat.r[2], // near
        };
    }

    fn isChunkInFrustum(self: *Renderer, chunk: *Chunk) bool {
        const world_max: F3 = @floatFromInt(chunk.world_max);
        const world_min: F3 = @floatFromInt(chunk.world_min);

        for (self.planes) |plane| {
            const point = F4{
                if (plane[0] >= 0) world_max[0] else world_min[0],
                if (plane[1] >= 0) world_max[1] else world_min[1],
                if (plane[2] >= 0) world_max[2] else world_min[2],
                1,
            };

            const dist = @reduce(.Add, point * plane);
            if (dist < 0) return false;
        }

        return true;
    }

    pub fn worldToChunkCoord(coord: WorldCoord, chunk_size: i32) ChunkCoord {
        const x_i = @as(i32, @intFromFloat(@floor(coord[0])));
        const y_i = @as(i32, @intFromFloat(@floor(coord[1])));
        const z_i = @as(i32, @intFromFloat(@floor(coord[2])));

        return .{
            @divFloor(x_i, chunk_size),
            @divFloor(y_i, chunk_size),
            @divFloor(z_i, chunk_size),
        };
    }

    /// Returns the avg of the two AABB points aka. chunk center
    pub fn chunkCenter(chunk: *const Chunk) @Vector(3, f32) {
        const half_vec = @as(@Vector(3, f32), @splat(0.5));
        const world_min: @Vector(3, f32) = @floatFromInt(chunk.world_min);
        const world_max: @Vector(3, f32) = @floatFromInt(chunk.world_max);

        return (world_min + world_max) * half_vec;
    }

    fn dist2ToPlayer(player: WorldCoord, chunk: *const Chunk) f32 {
        const c = chunkCenter(chunk);
        const d = c - player;
        return d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
    }

    pub fn worldVertexFromChunkVertex(
        vert: Vertex,
        chunk_pos: ChunkCoord,
        chunk_size: usize,
    ) WorldVertex {
        const v_pos_f: F3 = @floatFromInt(vert.pos);
        const chunk_pos_f: F3 = @floatFromInt(chunk_pos);
        const size_splat_f: F3 = @splat(@as(f32, @floatFromInt(chunk_size)));

        const temp: F3 = v_pos_f + chunk_pos_f * size_splat_f;
        const v_pos: F4 = .{ temp[0], temp[1], temp[2], 1 };

        return .{
            .pos = v_pos,
            .uv = vert.uv,
        };
    }

    pub fn renderWorld(
        self: *Renderer,
        allocator: std.mem.Allocator,
        player_pos: WorldCoord,
        chunk_size: usize,
        world: *World,
        camera: *Camera,
        terrain_generator: *TerrainGenerator,
    ) !void {
        const chunk_size_i: i32 = @intCast(chunk_size);
        const player_chunk = worldToChunkCoord(player_pos, chunk_size_i);
        const chunk_view_radius: i32 = @intFromFloat(@ceil(camera.view_distance /
            @as(f32, @floatFromInt(chunk_size))));

        self.chunk_entries.clearRetainingCapacity();

        // For a render radius R = chunk_view_radius, gather chunk coords around the player
        var cz = player_chunk[2] - chunk_view_radius;
        while (cz <= player_chunk[2] + chunk_view_radius) : (cz += 1) {
            var cy = player_chunk[1] - chunk_view_radius;
            while (cy <= player_chunk[1] + chunk_view_radius) : (cy += 1) {
                var cx = player_chunk[0] - chunk_view_radius;
                while (cx <= player_chunk[0] + chunk_view_radius) : (cx += 1) {
                    const dx = cx - player_chunk[0];
                    const dy = cy - player_chunk[1];
                    const dz = cz - player_chunk[2];
                    if (dx * dx + dy * dy + dz * dz > chunk_view_radius * chunk_view_radius) continue;

                    const coord = ChunkCoord{ cx, cy, cz };
                    const chunk = try world.ensureChunk(coord, terrain_generator);

                    if (!self.isChunkInFrustum(chunk)) continue;
                    if (chunk.meshing or chunk.queued or chunk.dirty) continue;

                    try self.chunk_entries.append(
                        allocator,
                        .{
                            .chunk = chunk,
                            .dist2 = dist2ToPlayer(player_pos, chunk),
                        },
                    );
                }
            }
        }

        // Front to back rendering
        std.sort.block(ChunkRenderEntry, self.chunk_entries.items, {}, struct {
            fn lessThan(_: void, a: ChunkRenderEntry, b: ChunkRenderEntry) bool {
                return a.dist2 < b.dist2;
            }
        }.lessThan);

        for (self.chunk_entries.items) |chunk| {
            // WARN: Part of LOD implementation, do not remove
            try generatePrimitivesFromChunk(chunk.chunk, camera.from, camera.combined_mat, allocator, self);
        }
    }
};

//// PRIMITIVE BUILDING & CULLING //////////////////////////////////////////////

/// Sutherland Hodgman algorithm can intersect the convex polygon in at most
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
    allocator: std.mem.Allocator,
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
        .pos_z => .{ .{ v_0, u_1 }, .{ v_1, u_1 }, .{ v_1, u_0 }, .{ v_0, u_0 } },
        .pos_x => .{ .{ u_1, v_1 }, .{ u_1, v_0 }, .{ u_0, v_0 }, .{ u_0, v_1 } },
        .neg_z => .{ .{ v_1, u_1 }, .{ v_1, u_0 }, .{ v_0, u_0 }, .{ v_0, u_1 } },
        .neg_x => .{ .{ u_0, v_1 }, .{ u_1, v_1 }, .{ u_1, v_0 }, .{ u_0, v_0 } },
        .pos_y => .{ .{ v_0, u_1 }, .{ v_0, u_0 }, .{ v_1, u_0 }, .{ v_1, u_1 } },
        .neg_y => .{ .{ v_0, u_0 }, .{ v_1, u_0 }, .{ v_1, u_1 }, .{ v_0, u_1 } },
    };

    // HACK: Rewrite cleanly after rewritting the RasterTriangle array
    // Maybe pass kind and block_id to the rasterizer directly, less mem traffic

    const quad = WorldQuad{
        .tex_tile_size = 16,
        .tex_u = @intFromEnum(kind) * TEX_SIZE,
        .tex_v = @intFromEnum(rq.block_id) * TEX_SIZE,
        .v0 = .{ .uv = verts_uv[0], .pos = verts_coord[0] },
        .v1 = .{ .uv = verts_uv[1], .pos = verts_coord[1] },
        .v2 = .{ .uv = verts_uv[2], .pos = verts_coord[2] },
        .v3 = .{ .uv = verts_uv[3], .pos = verts_coord[3] },
    };

    // Quad trivially inside

    if (or_code == 0) {
        try renderer.emitQuad(allocator, quad);
        return;
    }

    var clipped_polygon: ClippedPolygon = undefined;
    clipped_polygon.verts[0] = quad.v0;
    clipped_polygon.verts[1] = quad.v1;
    clipped_polygon.verts[2] = quad.v2;
    clipped_polygon.verts[3] = quad.v3;
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

    try renderer.emitPolygonFan(allocator, clipped_polygon, quad);
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
    allocator: std.mem.Allocator,
) !void {

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
        for (quads) |quad| try emitRenderQuad(
            kind,
            quad,
            chunk_min,
            combined_mat,
            allocator,
            renderer,
        );

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
            if (cam_axis > axis_world_coord + eps) try emitRenderQuad(
                kind,
                quad,
                chunk_min,
                combined_mat,
                allocator,
                renderer,
            );
        } else {
            if (cam_axis < axis_world_coord - eps) try emitRenderQuad(
                kind,
                quad,
                chunk_min,
                combined_mat,
                allocator,
                renderer,
            );
        }
    }
}

pub fn generatePrimitivesFromChunk(
    chunk: *Chunk,
    camera_pos: F3,
    combined_mat: Mat4f,
    allocator: std.mem.Allocator,
    renderer: *Renderer,
) !void {
    const min: F3 = @floatFromInt(chunk.world_min);
    const max: F3 = @floatFromInt(chunk.world_max);
    const pos = camera_pos;

    try emitBucket(.pos_x, chunk.mesh.pos_x_faces.items, pos[0], min[0], max[0], min, combined_mat, renderer, allocator);
    try emitBucket(.pos_y, chunk.mesh.pos_y_faces.items, pos[1], min[1], max[1], min, combined_mat, renderer, allocator);
    try emitBucket(.pos_z, chunk.mesh.pos_z_faces.items, pos[2], min[2], max[2], min, combined_mat, renderer, allocator);
    try emitBucket(.neg_x, chunk.mesh.neg_x_faces.items, pos[0], min[0], max[0], min, combined_mat, renderer, allocator);
    try emitBucket(.neg_y, chunk.mesh.neg_y_faces.items, pos[1], min[1], max[1], min, combined_mat, renderer, allocator);
    try emitBucket(.neg_z, chunk.mesh.neg_z_faces.items, pos[2], min[2], max[2], min, combined_mat, renderer, allocator);
}
