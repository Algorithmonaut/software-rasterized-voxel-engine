const std = @import("std");

const RasterTriangle = @import("triangle.zig").RasterTriangle;
const World = @import("World.zig").World;
const FramebufferConfig = @import("EngineConfig.zig").EngineConfig.FramebufferConfig;
const Camera = @import("Camera.zig").Camera;
const Chunk = @import("Chunk.zig").Chunk;
const Atlas = @import("Atlas.zig").Atlas;
const Mesher = @import("world/chunk-mesher.zig").Mesher;
const TerrainGenerator = @import("world/TerrainGenerator.zig").TerrainGenerator;

const Block = @import("world/Block.zig");
const WorldQuad = Block.WorldQuad;
const WorldVertex = Block.WorldVertex;
const WorldTriangle = Block.WorldTriangle;
const Vertex = Block.Vertex;

const Mat4f = @import("math/matrix.zig").Mat4f;

const types = @import("math/types.zig");
const Vec4f = types.Vec4f;
const Vec3f = types.Vec3f;
const Float = types.Float;
const Int = types.Int;
const WorldCoord = types.WorldCoord;
const ChunkCoord = types.ChunkCoord;

const Vec2fx = types.Vec2fx;
const SUBPIXEL_BITS = types.SUBPIXEL_BITS;
const SUBPIXEL_SCALE = types.SUBPIXEL_SCALE;

pub const Renderer = struct {
    triangles: std.ArrayList(RasterTriangle),
    chunk_entries: std.ArrayList(ChunkRenderEntry),

    fb_width: usize,
    fb_height: usize,
    tile_dimensions: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        conf: FramebufferConfig,
        view_distance: Float,
    ) !Renderer {
        // TODO: Find a better way to do this
        const half_view_dist: usize = @intFromFloat(view_distance / 2);
        const estimate = half_view_dist * half_view_dist * half_view_dist;

        return .{
            .triangles = try std.ArrayList(RasterTriangle).initCapacity(
                allocator,
                10_000,
            ),
            .chunk_entries = try std.ArrayList(ChunkRenderEntry).initCapacity(
                allocator,
                estimate,
            ),

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

    // QUAD RENDERING //////////////////////////////////////////////////////////

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

    // const ClipTriangle = struct {
    //     v0: WorldVertex,
    //     v1: WorldVertex,
    //     v2: WorldVertex,
    // };

    inline fn clipCode(v: Vec4f) u8 {
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
            .pos = v0.pos + @as(Vec4f, @splat(t)) * (v1.pos - v0.pos),
            .uv = v0.uv + @as(@Vector(2, f32), @splat(t)) * (v1.uv - v0.uv),
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

        for (0..polygon.len - 1) |i| {
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

        // Backface culling (vertices are oriented CCW)
        // Only need to check a single triangle
        const v0 = polygon.verts[0].pos;
        {
            const v1 = polygon.verts[1].pos;
            const v2 = polygon.verts[2].pos;
            const signed_area =
                (v1[0] - v0[0]) * (v2[1] - v0[1]) -
                (v1[1] - v0[1]) * (v2[0] - v0[0]);
            if (signed_area < 0) return;
        }

        // Clip -> NDC
        var rec_ws: [9]f32 = undefined;
        for (0..polygon.len) |i| {
            const rec_w = 1.0 / polygon.verts[i].pos[3];
            rec_ws[i] = rec_w;
            polygon.verts[i].pos *= @as(Vec4f, @splat(rec_w));
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

    // TODO: Maybe combine this function with the previous one

    /// Use if the quad is trivially inside
    fn emitQuad(
        self: *Renderer,
        allocator: std.mem.Allocator,
        quad: WorldQuad,
    ) !void {
        // Backface culling (vertices are oriented CCW)
        // Only need to check a single triangle
        var v = [4]Vec4f{ quad.v0.pos, quad.v1.pos, quad.v2.pos, quad.v3.pos };

        const signed_area =
            (v[1][0] - v[0][0]) * (v[2][1] - v[0][1]) -
            (v[1][1] - v[0][1]) * (v[2][0] - v[0][0]);
        if (signed_area < 0) return;

        // Clip -> NDC
        var rec_ws: [4]f32 = undefined;
        for (0..v.len) |i| {
            const rec_w = 1.0 / v[i][3];
            rec_ws[i] = rec_w;
            v[i] *= @as(Vec4f, @splat(rec_w));
        }

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

    fn emitClippedQuad(
        self: *Renderer,
        allocator: std.mem.Allocator,
        quad: WorldQuad,
    ) !void {
        const c0 = clipCode(quad.v0.pos);
        const c1 = clipCode(quad.v1.pos);
        const c2 = clipCode(quad.v2.pos);
        const c3 = clipCode(quad.v3.pos);

        const or_code = c0 | c1 | c2 | c3;
        const and_code = c0 & c1 & c2 & c3;

        if (and_code != 0) return; // quad trivially outside
        if (or_code == 0) { // quad trivially inside
            try emitClippedQuad(self, allocator, quad);
            return;
        }
        // if (or_code != 0) return; // TEMP: drop partially clipped tris

        var clipped_polygon: ClippedPolygon = undefined;
        clipped_polygon.verts[0] = quad.v0;
        clipped_polygon.verts[1] = quad.v1;
        clipped_polygon.verts[2] = quad.v2;
        clipped_polygon.verts[3] = quad.v3;
        clipped_polygon.len = 4;

        if (or_code & @intFromEnum(Plane.LEFT) != 0)
            clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.LEFT);

        if (or_code & @intFromEnum(Plane.RIGHT) != 0)
            clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.RIGHT);

        if (or_code & @intFromEnum(Plane.BOTTOM) != 0)
            clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.BOTTOM);

        if (or_code & @intFromEnum(Plane.TOP) != 0)
            clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.TOP);

        if (or_code & @intFromEnum(Plane.NEAR) != 0)
            clipped_polygon = clipPolygonAgainstPlane(clipped_polygon, Plane.NEAR);

        try emitPolygonFan(self, allocator, clipped_polygon, quad);
    }

    inline fn genRasterTriangleFromWorldQuad(
        self: *Renderer,
        allocator: std.mem.Allocator,
        quad: WorldQuad,
        combined_clip_transform: Mat4f,
    ) !void {
        var projected_quad = quad;
        projected_quad.v0.pos =
            combined_clip_transform.mul_vec(projected_quad.v0.pos);
        projected_quad.v1.pos =
            combined_clip_transform.mul_vec(projected_quad.v1.pos);
        projected_quad.v2.pos =
            combined_clip_transform.mul_vec(projected_quad.v2.pos);
        projected_quad.v3.pos =
            combined_clip_transform.mul_vec(projected_quad.v3.pos);

        try emitClippedQuad(self, allocator, projected_quad);
    }

    // CHUNK RENDERING /////////////////////////////////////////////////////////

    fn isChunkInFrustum(chunk: *Chunk, combined_mat: Mat4f) bool {
        const planes = [5]Vec4f{
            combined_mat.r[3] + combined_mat.r[0], // left
            combined_mat.r[3] - combined_mat.r[0], // right
            combined_mat.r[3] + combined_mat.r[1], // bottom
            combined_mat.r[3] - combined_mat.r[1], // top
            combined_mat.r[2], // near
        };

        const world_max: Vec3f = @floatFromInt(chunk.world_max);
        const world_min: Vec3f = @floatFromInt(chunk.world_min);

        for (planes) |plane| {
            const point = Vec4f{
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

    const ChunkRenderEntry = struct {
        chunk: *Chunk,
        dist2: f32,
    };

    pub fn worldVertexFromChunkVertex(
        vert: Vertex,
        chunk_pos: ChunkCoord,
        chunk_size: usize,
    ) WorldVertex {
        const v_pos_f: Vec3f = @floatFromInt(vert.pos);
        const chunk_pos_f: Vec3f = @floatFromInt(chunk_pos);
        const size_splat_f: Vec3f = @splat(@as(Float, @floatFromInt(chunk_size)));

        const temp: Vec3f = v_pos_f + chunk_pos_f * size_splat_f;
        const v_pos: Vec4f = .{ temp[0], temp[1], temp[2], 1 };

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
        terrain_generator: TerrainGenerator,
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

                    if (!isChunkInFrustum(chunk, camera.combined_mat)) continue;

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
            for (chunk.chunk.mesh.items) |quad| {
                const world_quad = WorldQuad{
                    .v0 = worldVertexFromChunkVertex(quad.v0, chunk.chunk.coord, chunk.chunk.dimensions),
                    .v1 = worldVertexFromChunkVertex(quad.v1, chunk.chunk.coord, chunk.chunk.dimensions),
                    .v2 = worldVertexFromChunkVertex(quad.v2, chunk.chunk.coord, chunk.chunk.dimensions),
                    .v3 = worldVertexFromChunkVertex(quad.v3, chunk.chunk.coord, chunk.chunk.dimensions),

                    .tex_tile_size = quad.atlas_tile_size,
                    .tex_u = quad.u,
                    .tex_v = quad.v,
                };

                try self.genRasterTriangleFromWorldQuad(allocator, world_quad, camera.combined_mat);
            }
        }
    }
};
