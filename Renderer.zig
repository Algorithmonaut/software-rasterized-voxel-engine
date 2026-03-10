const std = @import("std");
const ctx = @import("context.zig"); // WARN: To refactor
const Triangle = @import("triangle.zig").Triangle;
const RasterTriangle = @import("triangle.zig").RasterTriangle;
const Atlas = @import("Atlas.zig").Atlas;
const Camera = @import("Camera.zig").Camera;
const tile = @import("tile.zig");
const Framebuffer = @import("Framebuffer.zig").Framebuffer;

const t = @import("math/types.zig");
const Int = t.Int; // WARN: To refactor
const Uint = t.Uint;
const Vec4f = t.Vec4f;
const Vec3f = t.Vec3f;
const Float = t.Float;
const Chunk = @import("Chunk.zig").Chunk;
const Cube = @import("Cube.zig").Cube;
const World = @import("World.zig").World;

const cube_worker = @import("cube-worker.zig");

const WorldCoord = @import("math/types.zig").WorldCoord;
const ChunkCoord = @import("math/types.zig").ChunkCoord;

const FramebufferConfig = @import("EngineConfig.zig").EngineConfig.FramebufferConfig;
const CameraConfig = @import("EngineConfig.zig").EngineConfig.CameraConfig;

pub const Renderer = struct {
    triangles: []RasterTriangle,
    triangles_per_cube: []usize,

    width: usize,
    height: usize,
    tile_dimensions: usize,

    tile_counts: []usize,
    tile_offsets: []usize,
    write_pos: []usize, // Per tile write cursor
    tile_refs: []Uint, // FIX: CHANGE TO USIZE, IAM GETTING TIRED OF BEING DUMB
    chunk_entries: std.ArrayList(ChunkRenderEntry),

    pub fn init(
        allocator: std.mem.Allocator,
        conf: FramebufferConfig,
        tile_counts: usize,
        view_distance: f32,
    ) !Renderer {
        const side: usize = @intFromFloat(view_distance / 5);

        const estimated: usize = side * side * side; // AABB of the view sphere

        return .{
            // FIX: For now I consider pseudo AABB of the view sphere,
            // but later please implement alloc for the view sphere
            // Remove magic numbers here before I have a big issueMQLSJDLKJSDF KJSF
            .triangles = try allocator.alloc(RasterTriangle, estimated * 16 * 16 * 16 * 12),
            .triangles_per_cube = try allocator.alloc(usize, estimated * 16 * 16 * 16),

            .width = conf.width,
            .height = conf.height,
            .tile_dimensions = conf.tile_dimensions,
            .tile_counts = try allocator.alloc(usize, tile_counts),
            .tile_offsets = try allocator.alloc(usize, tile_counts + 1),
            .write_pos = try allocator.alloc(usize, tile_counts),
            .tile_refs = try allocator.alloc(Uint, 1000000), // Initial guess
            .chunk_entries = try std.ArrayList(ChunkRenderEntry).initCapacity(allocator, estimated),
        };
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        allocator.free(self.tile_counts);
        allocator.free(self.tile_offsets);
        allocator.free(self.write_pos);
        allocator.free(self.tile_refs);
        allocator.free(self.triangles_per_cube);
        self.chunk_entries.deinit(allocator);
    }

    pub fn begin_frame(self: *Renderer, allocator: std.mem.Allocator) !void {
        // self.triangles.clearRetainingCapacity();
        // try self.triangles.ensureTotalCapacity(allocator, cube_count * 6 * 2);
        _ = self;
        _ = allocator;
    }

    inline fn tile_range_for_tri(self: *Renderer, triangle: RasterTriangle) struct {
        min_tx: usize,
        max_tx: usize,
        min_ty: usize,
        max_ty: usize,
    } {
        const bb = triangle.bounding_box();

        // WARN: Change to divCeil if it does not work for max
        const min_tx = @divFloor(bb.min_x, self.tile_dimensions);
        const min_ty = @divFloor(bb.min_y, self.tile_dimensions);
        const max_tx = std.math.divCeil(usize, bb.max_x, self.tile_dimensions) catch unreachable;
        const max_ty = std.math.divCeil(usize, bb.max_y, self.tile_dimensions) catch unreachable;

        // WARN: Clamp to tile grid if necessary

        return .{ .min_tx = min_tx, .max_tx = max_tx, .min_ty = min_ty, .max_ty = max_ty };
    }

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

    pub inline fn gen_raster_triangle(
        self: *const Renderer,
        tri: *Triangle,
        camera: *Camera,
    ) ?RasterTriangle {
        var clip: [3]Vec4f = .{
            camera.proj_mat.mul_vec(.{ tri.v0[0], tri.v0[1], tri.v0[2], 1.0 }),
            camera.proj_mat.mul_vec(.{ tri.v1[0], tri.v1[1], tri.v1[2], 1.0 }),
            camera.proj_mat.mul_vec(.{ tri.v2[0], tri.v2[1], tri.v2[2], 1.0 }),
        };

        const code_0 = clip_outcode(clip[0]);
        const code_1 = clip_outcode(clip[1]);
        const code_2 = clip_outcode(clip[2]);
        if ((code_0 & code_1 & code_2) != 0) return null;

        var rec_ws: Vec3f = undefined; // reciprocal of w = reciprocal of z in camera space

        inline for (&clip, 0..) |*vert_h, i| {
            const clip_w = vert_h[3];
            const inv_w = 1.0 / clip_w;
            rec_ws[i] = inv_w;
            vert_h.* = vert_h.* * @as(Vec4f, @splat(inv_w));

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

        return .{
            .v0 = a,
            .v1 = b,
            .v2 = c,
            .v0_rec_z = rec_ws[0],
            .v1_rec_z = rec_ws[1],
            .v2_rec_z = rec_ws[2],
            .v0_uv = tri.v0_uv,
            .v1_uv = tri.v1_uv,
            .v2_uv = tri.v2_uv,
        };
    }

    ////////////////////////////////////////////////////////////////////////////

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

                        try self.chunk_entries.appendBounded(
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
            const cubes_per_chunk = chunk_size * chunk_size * chunk_size;
            const chunk_offset = chunk_i * cubes_per_chunk;

            // Then we render the chunk
            for (0..chunk.chunk.voxels.len) |i| {
                var cube_grass = Cube.init(.grass); // for now we render everything as a grass block

                // Coordinates of the block in the chunk
                const x_chunk: Float = @floatFromInt(i / (chunk_size * chunk_size) * 2);
                const y_chunk: Float = @floatFromInt(((i / chunk_size) % chunk_size) * 2);
                const z_chunk: Float = @floatFromInt((i % chunk_size) * 2);

                // Coordinates of the block in world space
                const x: Float = x_chunk + @as(Float, @floatFromInt(chunk.chunk.coord[0] * chunk_size_i));
                const y: Float = y_chunk + @as(Float, @floatFromInt(chunk.chunk.coord[1] * chunk_size_i));
                const z: Float = z_chunk + @as(Float, @floatFromInt(chunk.chunk.coord[2] * chunk_size_i));

                const cube_start = chunk_offset * 12 + i * 12;
                const cube_end = cube_start + 12;
                self.triangles_per_cube[chunk_offset + i] =
                    cube_grass.genRasterTriangles(self, camera, atlas, self.triangles[cube_start..cube_end], .{ x, y, z, 0 });
            }
        }
    }
};
