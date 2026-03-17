const std = @import("std");

const RasterTriangle = @import("triangle.zig").RasterTriangle;
const World = @import("World.zig").World;
const FramebufferConfig = @import("EngineConfig.zig").EngineConfig.FramebufferConfig;
const Camera = @import("Camera.zig").Camera;
const Chunk = @import("Chunk.zig").Chunk;
const Atlas = @import("Atlas.zig").Atlas;

const Block = @import("world/Block.zig");
const WorldQuad = Block.WorldQuad;
const WorldVertex = Block.WorldVertex;
const WorldTriangle = Block.WorldTriangle;

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
        const half_view_dist = view_distance / 2;
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

    fn clip_outcode(v: Vec4f) u8 {
        var code: u8 = 0; // bitfield
        if (v[0] < -v[3]) code |= 1 << 0; // left
        if (v[0] > v[3]) code |= 1 << 1; // right
        if (v[1] < -v[3]) code |= 1 << 2; // bottom
        if (v[1] > v[3]) code |= 1 << 3; // top
        if (v[2] < 0) code |= 1 << 4; // near
        if (v[2] > v[3]) code |= 1 << 5; // far
        return code;
    }

    pub inline fn genRasterTriangleFromWorldTriangle(
        self: *Renderer,
        allocator: std.mem.Allocator,
        tri: WorldTriangle,
        camera: *Camera, // TODO: Pass the projection matrix directly for clarity
    ) void {
        // First we project the WorldTriangle in clip space
        var clip: [3]Vec4f = .{
            camera.proj_mat.mul_vec(.{ tri.v0[0], tri.v0[1], tri.v0[2], 1.0 }),
            camera.proj_mat.mul_vec(.{ tri.v1[0], tri.v1[1], tri.v1[2], 1.0 }),
            camera.proj_mat.mul_vec(.{ tri.v2[0], tri.v2[1], tri.v2[2], 1.0 }),
        };

        // Then we do culling for the 6 planes
        const code_0 = clip_outcode(clip[0]);
        const code_1 = clip_outcode(clip[1]);
        const code_2 = clip_outcode(clip[2]);
        if ((code_0 & code_1 & code_2) != 0) return null;

        var rec_ws: Vec3f = undefined; // rec of w = rec of z in clip space

        // We normalize by w and store reciprocal w in an array (is it necessary?)
        inline for (&clip, 0..) |*vert_h, i| {
            const clip_w = vert_h[3];
            const inv_w = 1.0 / clip_w;
            rec_ws[i] = inv_w;
            vert_h.* = vert_h.* * @as(Vec4f, @splat(inv_w)); // we normalize

            clip[i] = vert_h.*;
        }

        const v0 = clip[0];
        const v1 = clip[1];
        const v2 = clip[2];

        // Backface culling
        const signed_area = (v1[0] - v0[0]) * (v2[1] - v0[1]) -
            (v1[1] - v0[1]) * (v2[0] - v0[0]);
        if (signed_area > 0) return null;

        // P: Clip -> raster
        const fw: Float = @floatFromInt(self.width);
        const fh: Float = @floatFromInt(self.height);

        const a = @Vector(2, Int){
            @intFromFloat((v0[0] + 1.0) * 0.5 * fw + 0.5),
            @intFromFloat((1 - (v0[1] + 1.0) * 0.5) * fh + 0.5),
        };

        const b = @Vector(2, Int){
            @intFromFloat((v1[0] + 1.0) * 0.5 * fw + 0.5),
            @intFromFloat((1 - (v1[1] + 1.0) * 0.5) * fh + 0.5),
        };

        const c = @Vector(2, Int){
            @intFromFloat((v2[0] + 1.0) * 0.5 * fw + 0.5),
            @intFromFloat((1 - (v2[1] + 1.0) * 0.5) * fh + 0.5),
        };

        self.triangles.append(allocator, .{
            .v0 = a,
            .v1 = b,
            .v2 = c,
            .v0_rec_z = rec_ws[0],
            .v1_rec_z = rec_ws[1],
            .v2_rec_z = rec_ws[2],
            .v0_uv = tri.v0_uv,
            .v1_uv = tri.v1_uv,
            .v2_uv = tri.v2_uv,
        });
    }

    pub inline fn genRasterTriangleFromWorldQuad(
        self: *Renderer,
        allocator: std.mem.Allocator,
        camera: *Camera,
        quad: *WorldQuad,
    ) void {
        // NOTE: Maybe my triangles vertices aren't set in the correct order
        const tri_1 = WorldTriangle{
            .v0 = quad.v0,
            .v1 = quad.v1,
            .v2 = quad.v3,
        };

        const tri_2 = WorldTriangle{
            .v0 = quad.v1,
            .v1 = quad.v2,
            .v2 = quad.v3,
        };

        self.genRasterTriangleFromWorldTriangle(allocator, tri_1, camera);
        self.genRasterTriangleFromWorldTriangle(allocator, tri_2, camera);
    }

    // CHUNK RENDERING /////////////////////////////////////////////////////////

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

    pub fn renderWorld(
        self: *Renderer,
        allocator: std.mem.Allocator,
        player_pos: WorldCoord,
        view_distance: i32,
        chunk_size: usize,
        world: *World,
        camera: *Camera,
        atlas: *Atlas,
    ) !void {
        const chunk_size_i: i32 = @intCast(chunk_size);
        const player_chunk = worldToChunkCoord(player_pos, chunk_size_i);

        self.chunk_entries.clearRetainingCapacity();

        // For a render radius R = view_distance, gather chunk coords around the player
        var cz = player_chunk[2] - view_distance;
        while (cz <= player_chunk[2] + view_distance) : (cz += 1) {
            var cy = player_chunk[1] - view_distance;
            while (cy <= player_chunk[1] + view_distance) : (cy += 1) {
                var cx = player_chunk[0] - view_distance;
                while (cx <= player_chunk[0] + view_distance) : (cx += 1) {
                    const coord = ChunkCoord{ cx, cy, cz };

                    if (world.getChunk(coord)) |chunk| {
                        // TODO: Frustum cull here first

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
        }

        // Front to back rendering
        std.sort.block(ChunkRenderEntry, self.chunk_entries.items, {}, struct {
            fn lessThan(_: void, a: ChunkRenderEntry, b: ChunkRenderEntry) bool {
                return a.dist2 < b.dist2;
            }
        }.lessThan);

        for (self.chunk_entries.items, 0..) |chunk, chunk_i| {
            _ = chunk;
            _ = chunk_i;

            // TODO: For all the quads in the mesh,
            // generate the world mesh, and render
        }
    }
};
