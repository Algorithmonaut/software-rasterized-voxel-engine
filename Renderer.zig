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

    const ClipTriangle = struct {
        v0: WorldVertex,
        v1: WorldVertex,
        v2: WorldVertex,
    };

    inline fn clipOutcode(v: Vec4f) u8 {
        var code: u8 = 0; // bitfield
        if (v[0] < -v[3]) code |= 1 << 0; // left
        if (v[0] > v[3]) code |= 1 << 1; // right
        if (v[1] < -v[3]) code |= 1 << 2; // bottom
        if (v[1] > v[3]) code |= 1 << 3; // top
        // if (v[2] < 0) code |= 1 << 4; // near
        return code;
    }

    inline fn nearMask(tri: ClipTriangle) u3 {
        var mask: u3 = 0;
        if (nearInside(tri.v0.pos)) mask |= 1;
        if (nearInside(tri.v1.pos)) mask |= 2;
        if (nearInside(tri.v2.pos)) mask |= 4;
        return mask;
    }

    inline fn nearInside(pos: Vec4f) bool {
        return (pos[2] >= -pos[3]);
    }

    inline fn emitRasterTriangle(
        self: *Renderer,
        allocator: std.mem.Allocator,
        v0: WorldVertex,
        v1: WorldVertex,
        v2: WorldVertex,
        quad: WorldQuad,
    ) !void {
        var p0 = v0.pos;
        var p1 = v1.pos;
        var p2 = v2.pos;

        const rec_w0 = 1.0 / p0[3];
        const rec_w1 = 1.0 / p1[3];
        const rec_w2 = 1.0 / p2[3];

        p0 *= @as(Vec4f, @splat(rec_w0));
        p1 *= @as(Vec4f, @splat(rec_w1));
        p2 *= @as(Vec4f, @splat(rec_w2));

        // Backface culling (vertices are oriented CCW)
        const signed_area =
            (p1[0] - p0[0]) * (p2[1] - p0[1]) -
            (p1[1] - p0[1]) * (p2[0] - p0[0]);
        if (signed_area < 0) return;

        // Clip -> raster
        const fw: Float = @floatFromInt(self.fb_width);
        const fh: Float = @floatFromInt(self.fb_height);

        // The clip -> raster conversion of Y flips the triangle's
        // orientation (CCW -> CW)
        const a = @Vector(2, Int){
            @intFromFloat((p0[0] + 1.0) * 0.5 * fw),
            @intFromFloat((1.0 - (p0[1] + 1.0) * 0.5) * fh),
        };

        const b = @Vector(2, Int){
            @intFromFloat((p1[0] + 1.0) * 0.5 * fw),
            @intFromFloat((1.0 - (p1[1] + 1.0) * 0.5) * fh),
        };

        const c = @Vector(2, Int){
            @intFromFloat((p2[0] + 1.0) * 0.5 * fw),
            @intFromFloat((1.0 - (p2[1] + 1.0) * 0.5) * fh),
        };

        try self.triangles.append(allocator, .{
            .v0 = a,
            .v1 = b,
            .v2 = c,
            .q0 = rec_w0,
            .q1 = rec_w1,
            .q2 = rec_w2,
            .uv0 = v0.uv,
            .uv1 = v1.uv,
            .uv2 = v2.uv,

            .tex_u = quad.tex_u,
            .tex_v = quad.tex_v,
            .tex_tile_size = quad.tex_tile_size,
        });
    }

    inline fn intersectNear(a: WorldVertex, b: WorldVertex) WorldVertex {
        const fa = a.pos[2] + a.pos[3];
        const fb = b.pos[2] + b.pos[3];
        const t = -fa / (fb - fa);
        const t_uv_vec: @Vector(2, Float) = @splat(t);

        return .{
            .pos = a.pos + @as(Vec4f, @splat(t)) * (b.pos - a.pos),
            .uv = a.uv + t_uv_vec * (b.uv - a.uv),
        };
    }

    inline fn emitClippedTriangle(
        self: *Renderer,
        allocator: std.mem.Allocator,
        tri: ClipTriangle,
        quad: WorldQuad,
    ) !void {
        const m = nearMask(tri);

        switch (m) {
            0b000 => return,

            0b111 => {
                try self.emitRasterTriangle(allocator, tri.v0, tri.v1, tri.v2, quad);
            },

            // only v0 inside
            0b001 => {
                const isect01 = intersectNear(tri.v0, tri.v1);
                const isect02 = intersectNear(tri.v0, tri.v2);
                try self.emitRasterTriangle(allocator, tri.v0, isect01, isect02, quad);
            },

            // only v1 inside
            0b010 => {
                const isect10 = intersectNear(tri.v1, tri.v0);
                const isect12 = intersectNear(tri.v1, tri.v2);
                try self.emitRasterTriangle(allocator, tri.v1, isect12, isect10, quad);
            },

            // only v2 inside
            0b100 => {
                const isect20 = intersectNear(tri.v2, tri.v0);
                const isect21 = intersectNear(tri.v2, tri.v1);
                try self.emitRasterTriangle(allocator, tri.v2, isect20, isect21, quad);
            },

            // v0, v1 inside; v2 outside
            0b011 => {
                const isect12 = intersectNear(tri.v1, tri.v2);
                const isect02 = intersectNear(tri.v0, tri.v2);
                try self.emitRasterTriangle(allocator, tri.v0, tri.v1, isect12, quad);
                try self.emitRasterTriangle(allocator, tri.v0, isect12, isect02, quad);
            },

            // v0, v2 inside; v1 outside
            0b101 => {
                const isect01 = intersectNear(tri.v0, tri.v1);
                const isect21 = intersectNear(tri.v2, tri.v1);
                try self.emitRasterTriangle(allocator, tri.v0, isect01, tri.v2, quad);
                try self.emitRasterTriangle(allocator, isect01, isect21, tri.v2, quad);
            },

            // v1, v2 inside; v0 outside
            0b110 => {
                const isect10 = intersectNear(tri.v1, tri.v0);
                const isect20 = intersectNear(tri.v2, tri.v0);
                try self.emitRasterTriangle(allocator, tri.v1, tri.v2, isect20, quad);
                try self.emitRasterTriangle(allocator, tri.v1, isect20, isect10, quad);
            },
        }
    }

    inline fn genRasterTriangleFromWorldQuad(
        self: *Renderer,
        allocator: std.mem.Allocator,
        quad: WorldQuad,
        combined_clip_transform: Mat4f,
    ) !void {
        const cv0 = WorldVertex{
            .pos = combined_clip_transform.mul_vec(quad.v0.pos),
            .uv = quad.v0.uv,
        };
        const cv1 = WorldVertex{
            .pos = combined_clip_transform.mul_vec(quad.v1.pos),
            .uv = quad.v1.uv,
        };
        const cv2 = WorldVertex{
            .pos = combined_clip_transform.mul_vec(quad.v2.pos),
            .uv = quad.v2.uv,
        };
        const cv3 = WorldVertex{
            .pos = combined_clip_transform.mul_vec(quad.v3.pos),
            .uv = quad.v3.uv,
        };

        // Trivial reject for the 5 planes (far plane excluded)
        const code_0 = clipOutcode(cv0.pos);
        const code_1 = clipOutcode(cv1.pos);
        const code_2 = clipOutcode(cv2.pos);
        const code_3 = clipOutcode(cv3.pos);
        if ((code_0 & code_1 & code_2 & code_3) != 0) return;

        try self.emitClippedTriangle(allocator, .{
            .v0 = cv0,
            .v1 = cv1,
            .v2 = cv3,
        }, quad);

        try self.emitClippedTriangle(allocator, .{
            .v0 = cv1,
            .v1 = cv2,
            .v2 = cv3,
        }, quad);
    }

    // CHUNK RENDERING /////////////////////////////////////////////////////////

    fn isChunkInFrustum(chunk: *Chunk, combined_mat: Mat4f) bool {
        const planes = [5]Vec4f{
            combined_mat.r[3] + combined_mat.r[0], // left
            combined_mat.r[3] - combined_mat.r[0], // right
            combined_mat.r[3] + combined_mat.r[1], // bottom
            combined_mat.r[3] - combined_mat.r[1], // top
            combined_mat.r[3] + combined_mat.r[2], // near
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

    fn worldToChunkCoord(coord: WorldCoord, chunk_size: i32) ChunkCoord {
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
