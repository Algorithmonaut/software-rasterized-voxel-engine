const std = @import("std");
const ctx = @import("context.zig"); // WARN: To refactor
const cfg = @import("config.zig");
const Triangle = @import("triangle.zig").Triangle;
const RasterTriangle = @import("triangle.zig").RasterTriangle;
const Atlas = @import("Atlas.zig").Atlas;
const Camera = @import("Camera.zig").Camera;
const tile = @import("tile.zig");
const Framebuffer = @import("Framebuffer.zig").Framebuffer;
const Int = cfg.Int; // WARN: To refactor
const Uint = cfg.Uint;
const Vec4f = cfg.Vec4f;
const Vec3f = cfg.Vec3f;
const Float = cfg.Float;
const Chunk = @import("Chunk.zig").Chunk;
const Cube = @import("Cube.zig").Cube;

const cube_worker = @import("cube-worker.zig");

const FramebufferConfig = @import("EngineConfig.zig").EngineConfig.FramebufferConfig;
pub const cube_count = 10000; // FIX: Change this shit

const AtomicUsize = std.atomic.Value(usize);

const batch_size: usize = 16;

fn tile_worker(
    next: *AtomicUsize,
    renderer: *const Renderer,
    tiles_pool: *tile.TilePool,
    buf: Framebuffer,
    tile_offsets: []const usize,
    tile_refs: []const cfg.Uint,
    atlas: *Atlas,
) void {
    while (true) {
        const tile_base = next.fetchAdd(batch_size, .monotonic);
        if (tile_base >= tiles_pool.tiles_count) break;

        for (0..batch_size) |incr| {
            const tile_i = tile_base + incr;
            if (tile_i >= tiles_pool.tiles_count) break;

            const start = tile_offsets[tile_i];
            const end = tile_offsets[tile_i + 1];

            if (start == end) continue;

            var t = &tiles_pool.tiles[tile_i];
            t.clear();

            for (tile_refs[start..end]) |tri_i_u| {
                const tri_i: usize = @intCast(tri_i_u);
                renderer.triangles[tri_i].render_triangle_in_tile(t, atlas);
            }

            t.write_to_fb(buf);
        }
    }
}

pub const Renderer = struct {
    triangles: []RasterTriangle,
    cubes_triangles_count: []usize,

    width: usize,
    height: usize,
    tile_dimensions: usize,

    tile_counts: []usize,
    tile_offsets: []usize,
    write_pos: []usize, // Per tile write cursor
    tile_refs: []Uint, // FIX: CHANGE TO USIZE, IAM GETTING TIRED OF BEING DUMB

    pub fn init(allocator: std.mem.Allocator, conf: FramebufferConfig, tile_counts: usize) !Renderer {
        return .{
            .triangles = try allocator.alloc(
                RasterTriangle,
                20 * 16 * 16 * 16 * 12, // 20 chunks
            ), // FIX: Change me
            .cubes_triangles_count = try allocator.alloc(usize, cube_count),

            .width = conf.width,
            .height = conf.height,
            .tile_dimensions = conf.tile_dimensions,
            .tile_counts = try allocator.alloc(usize, tile_counts),
            .tile_offsets = try allocator.alloc(usize, tile_counts + 1),
            .write_pos = try allocator.alloc(usize, tile_counts),
            .tile_refs = try allocator.alloc(Uint, 1000000), // Initial guess
        };
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        allocator.free(self.tile_counts);
        allocator.free(self.tile_offsets);
        allocator.free(self.write_pos);
        allocator.free(self.tile_refs);
        allocator.free(self.cubes_triangles_count);
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

    fn ensureTileRefsCapacity(
        self: *Renderer,
        allocator: std.mem.Allocator,
        needed: usize,
    ) !void {
        if (self.tile_refs.len >= needed) return;

        const new_cap = @max(self.tile_refs.len * 8, needed); // Maybe 8 is a bit too much
        const new_buf = try allocator.alloc(Uint, new_cap);
        allocator.free(self.tile_refs);
        self.tile_refs = new_buf;
    }

    pub fn render(
        self: *Renderer,
        pool: *std.Thread.Pool,
        tiles_pool: *tile.TilePool,
        buf: Framebuffer,
        allocator: std.mem.Allocator,
        atlas: *Atlas,
    ) !void {
        // P: First pass (count the triangles for each tile)
        @memset(self.tile_counts[0..], 0);

        for (0..self.cubes_triangles_count.len) |cube_idx| {
            const count = self.cubes_triangles_count[cube_idx];
            if (count == 0) continue;

            const base = cube_idx * 12;

            for (self.triangles[base .. base + count]) |triangle| {
                const range = tile_range_for_tri(self, triangle);

                var x = range.min_tx;
                while (x < range.max_tx) : (x += 1) {
                    var y = range.min_ty;
                    while (y < range.max_ty) : (y += 1) {
                        const idx = x + tiles_pool.tiles_count_w * y;
                        self.tile_counts[idx] += 1;
                        tiles_pool.tiles[idx].was_occupied = true;
                    }
                }
            }
        }

        var sum: usize = 0;
        for (0..tiles_pool.tiles_count) |t| {
            self.tile_offsets[t] = sum;
            sum += @as(usize, self.tile_counts[t]);
        }
        self.tile_offsets[tiles_pool.tiles_count] = sum;

        try self.ensureTileRefsCapacity(allocator, sum);

        // FIX: Change to a memcpy
        for (0..tiles_pool.tiles_count) |t| self.write_pos[t] = self.tile_offsets[t];

        // P: Second pass (scatter triangle indices into tile_refs)
        for (0..self.cubes_triangles_count.len) |cube_idx| {
            const count = self.cubes_triangles_count[cube_idx];
            if (count == 0) continue;

            const base = cube_idx * 12;

            for (self.triangles[base .. base + count], base..base + count) |triangle, tri_i| {
                const range = tile_range_for_tri(self, triangle);

                var tx = range.min_tx;
                while (tx < range.max_tx) : (tx += 1) {
                    var ty = range.min_ty;
                    while (ty < range.max_ty) : (ty += 1) {
                        const tile_i = tx + tiles_pool.tiles_count_w * ty;

                        const dst = self.write_pos[tile_i];
                        self.tile_refs[dst] = @intCast(tri_i);
                        self.write_pos[tile_i] = dst + 1;
                    }
                }
            }
        }

        // P: Third pass (render per tile and blit) - PARALLEL
        var next = AtomicUsize.init(0);
        var wg = std.Thread.WaitGroup{};
        const worker_count = try std.Thread.getCpuCount();

        for (0..worker_count) |_| {
            pool.spawnWg(&wg, tile_worker, .{ &next, self, tiles_pool, buf, self.tile_offsets, self.tile_refs, atlas });
        }

        wg.wait();
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

    pub fn renderChunk(self: *Renderer, allocator: std.mem.Allocator, chunk: *Chunk, camera: *Camera, atlas: *Atlas, pool: std.Thread.Pool) !void {
        var cube_grass = Cube.init(.grass);
        // const cube_dirt = Cube.init(.dirt);
        // const cube_stone = Cube.init(.stone);
        _ = pool;
        _ = allocator;

        for (0..chunk.voxels.len) |i| {
            const x: Float = @floatFromInt(i / (chunk.dimensions * chunk.dimensions) * 2);
            const y: Float = @floatFromInt(((i / chunk.dimensions) % chunk.dimensions) * 2);
            const z: Float = @floatFromInt((i % chunk.dimensions) * 2);

            // For now we render everything as grass blocks
            self.cubes_triangles_count[i] = cube_grass.genRasterTriangles(self, camera, atlas, self.triangles[i * 12 .. i * 12 + 12], .{ x, y, z, 0 });
        }
    }
};
