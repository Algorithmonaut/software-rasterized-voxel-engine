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
    pub const ChunkRenderEntry = struct { chunk: *Chunk, dist2: f32 };
    pub const ProjectedVertex = struct { xy: Vec2fx, q: f32, uv: UV };
    pub const MaterialRef = struct { tex_u: u16, tex_v: u16 };
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

        std.debug.print("ProjectedVertex: size={}, align={}\n", .{
            @sizeOf(ProjectedVertex),
            @alignOf(ProjectedVertex),
        });
        std.debug.print("MaterialRef: size={}, align={}\n", .{
            @sizeOf(MaterialRef),
            @alignOf(MaterialRef),
        });
        std.debug.print("PrimitiveRef: size={}, align={}\n", .{
            @sizeOf(PrimitiveRef),
            @alignOf(PrimitiveRef),
        });

        return .{
            // TODO: I presume that these are good estimates, but please investigate
            .frame_primitives = try std.ArrayList(PrimitiveRef).initCapacity(allocator, 70_000),
            .frame_materials = try std.ArrayList(MaterialRef).initCapacity(allocator, 70_000),
            .frame_vertices = try std.ArrayList(ProjectedVertex).initCapacity(allocator, 140_000),

            .chunk_entries = try std.ArrayList(ChunkRenderEntry).initCapacity(allocator, 100),
            .fb_width = conf.width,
            .fb_height = conf.height,
            .tile_dimensions = conf.tile_dimensions,
        };
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        self.frame_primitives.deinit(allocator);
        self.frame_materials.deinit(allocator);
        self.frame_vertices.deinit(allocator);
        self.chunk_entries.deinit(allocator);
    }

    inline fn ndcToScreenFixedPoint(
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

    /// No need to do backface culling anymore
    inline fn emitQuad(
        self: *Renderer,
        verts_coord: *const [4]F4,
        verts_uv: *const [4]UV,
        tex_u: usize,
        tex_v: usize,
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

        const tile_dim = self.tile_dimensions;
        const base: u32 = @intCast(self.frame_vertices.items.len);
        self.frame_vertices.appendSliceAssumeCapacity(vertices);
        self.frame_primitives.appendAssumeCapacity(.{
            .base_vertex = base,
            .vertex_count = 4,
            .min_tx = @divFloor(min_x, tile_dim),
            .min_ty = @divFloor(min_y, tile_dim),
            .max_tx = std.math.divCeil(i32, max_x, tile_dim) catch unreachable,
            .max_ty = std.math.divCeil(i32, max_y, tile_dim) catch unreachable,
        });
        self.frame_materials.appendAssumeCapacity(.{
            .tex_u = tex_u,
            .tex_v = tex_v,
        });
    }

    inline fn emitPolygon(
        self: *Renderer,
        polygon: *ClippedPolygon,
        tex_u: usize,
        tex_v: usize,
    ) void {
        const len = polygon.len;
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

        const tile_dim = self.tile_dimensions;
        const base: u32 = @intCast(self.frame_vertices.items.len);
        self.frame_vertices.appendAssumeCapacity(vertices[0..len]);
        self.frame_primitives.appendAssumeCapacity(.{
            .base_vertex = base,
            .vertex_count = len,
            .min_tx = @divFloor(min_x, tile_dim),
            .min_ty = @divFloor(min_y, tile_dim),
            .max_tx = std.math.divCeil(i32, max_x, tile_dim) catch unreachable,
            .max_ty = std.math.divCeil(i32, max_y, tile_dim) catch unreachable,
        });
        self.frame_materials.appendAssumeCapacity(.{
            .tex_u = tex_u,
            .tex_v = tex_v,
        });
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

    // Quad trivially inside

    const tex_u: u16 = @intFromEnum(kind) * TEX_SIZE;
    const tex_v: u16 = @intFromEnum(rq.block_id) * TEX_SIZE;

    if (or_code == 0) {
        renderer.emitQuad(&verts_coord, &verts_uv, tex_u, tex_v);
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

    if ((or_code & @intFromEnum(Plane.LEFT)) != 0)
        clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.LEFT);
    if (clipped_polygon.len < 3) return;
    if ((or_code & @intFromEnum(Plane.RIGHT)) != 0)
        clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.RIGHT);
    if (clipped_polygon.len < 3) return;
    if ((or_code & @intFromEnum(Plane.BOTTOM)) != 0)
        clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.BOTTOM);
    if (clipped_polygon.len < 3) return;
    if ((or_code & @intFromEnum(Plane.TOP)) != 0)
        clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.TOP);
    if ((or_code & @intFromEnum(Plane.NEAR)) != 0)
        clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.NEAR);

    renderer.emitPolygon(clipped_polygon.verts);
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
            if (cam_axis > axis_world_coord + eps) try emitRenderQuad(
                kind,
                quad,
                chunk_min,
                combined_mat,
                renderer,
            );
        } else {
            if (cam_axis < axis_world_coord - eps) try emitRenderQuad(
                kind,
                quad,
                chunk_min,
                combined_mat,
                renderer,
            );
        }
    }
}

pub fn generatePrimitivesFromChunk(
    chunk: *Chunk,
    camera_pos: F3,
    combined_mat: Mat4f,
    renderer: *Renderer,
) !void {
    const min: F3 = @floatFromInt(chunk.world_min);
    const max: F3 = @floatFromInt(chunk.world_max);
    const pos = camera_pos;

    try emitBucket(.pos_x, chunk.mesh.pos_x_faces.items, pos[0], min[0], max[0], min, combined_mat, renderer);
    try emitBucket(.pos_y, chunk.mesh.pos_y_faces.items, pos[1], min[1], max[1], min, combined_mat, renderer);
    try emitBucket(.pos_z, chunk.mesh.pos_z_faces.items, pos[2], min[2], max[2], min, combined_mat, renderer);
    try emitBucket(.neg_x, chunk.mesh.neg_x_faces.items, pos[0], min[0], max[0], min, combined_mat, renderer);
    try emitBucket(.neg_y, chunk.mesh.neg_y_faces.items, pos[1], min[1], max[1], min, combined_mat, renderer);
    try emitBucket(.neg_z, chunk.mesh.neg_z_faces.items, pos[2], min[2], max[2], min, combined_mat, renderer);
}
