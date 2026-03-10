// NOTE: Possible refactor
// binning.zig -> passes 1 and 2
// workers (or keep them local)
// triangle_in_tile (pixel loop only)
// TriangleRasterizer.zig -> orchestrates everything

const std = @import("std");

const RasterTriangle = @import("../triangle.zig").RasterTriangle;
const Tile = @import("../tile.zig").Tile;
const Atlas = @import("../Atlas.zig").Atlas;
const TilePool = @import("../tile.zig").TilePool;
const Framebuffer = @import("../Framebuffer.zig").Framebuffer;

const Float = @import("../math/types.zig").Float;
const Vec3i = @import("../math/types.zig").Vec3i;
const Vec3f = @import("../math/types.zig").Vec3f;
const AtomicUsize = std.atomic.Value(usize);

const Edge = struct {
    // Edge function can be refactored: E(x,y) = Ax + By + C with A B C constants
    A: i32,
    B: i32,
    C: i32, // WARN: Change to i64 if overflow

    bias: i32,

    /// Evaluate the point (x, y) against the edge
    inline fn eval(self: Edge, x: i32, y: i32) i64 {
        return self.A * x + self.B * y + self.C;
    }
};

/// Create Edge from two (oriented) vertex
inline fn makeEdge(a: @Vector(2, i32), b: @Vector(2, i32)) Edge {
    const x0 = a[0];
    const y0 = a[1];
    const x1 = b[0];
    const y1 = b[1];
    const dy = y1 - y0;
    const dx = x1 - x0;

    const is_top_left: bool = (dy > 0) or (dy == 0 and dx < 0);

    // E(x,y) = (y1 - y0)*x + (x0 - x1)*y + (y0*x1 - x0*y1)
    return .{
        .A = y1 - y0,
        .B = x0 - x1,
        .C = y0 * x1 - x0 * y1,
        .bias = if (is_top_left) 0 else -1,
    };
}

////////////////////////////////////////////////////////////////////////////////

// NOTE: TO VERIFY
inline fn renderTriangleInTile(
    triangle: *const RasterTriangle,
    tile: *Tile,
    atlas: *Atlas,
) void {
    const a = triangle.v0;
    const b = triangle.v1;
    const c = triangle.v2;

    const e0 = makeEdge(c, b);
    const e1 = makeEdge(a, c);
    const e2 = makeEdge(b, a);
    const area = e0.eval(a[0], a[1]);

    if (area == 0) return; // triangle is degenerate

    const inv_area = 1 / @as(Float, @floatFromInt(area));

    const tx0: i32 = @intCast(tile.pos[0]);
    const ty0: i32 = @intCast(tile.pos[1]);

    // P: Evaluate edges at top-left of tile
    const w0_row = e0.eval(tx0, ty0);
    const w1_row = e1.eval(tx0, ty0);
    const w2_row = e2.eval(tx0, ty0);
    var w_row = @Vector(3, i64){ w0_row, w1_row, w2_row };

    // P: Reciprocal depth at the vertices
    const q0: Float = triangle.v0_rec_z;
    const q1: Float = triangle.v1_rec_z;
    const q2: Float = triangle.v2_rec_z;

    const Uvf = @Vector(2, Float);

    const uv0f: Uvf = @floatFromInt(triangle.v0_uv);
    const uv1f: Uvf = @floatFromInt(triangle.v1_uv);
    const uv2f: Uvf = @floatFromInt(triangle.v2_uv);

    const uv0q: Uvf = uv0f * @as(Uvf, @splat(q0));
    const uv1q: Uvf = uv1f * @as(Uvf, @splat(q1));
    const uv2q: Uvf = uv2f * @as(Uvf, @splat(q2));

    // P: Step vectors
    const right_inc = Vec3i{ e0.A, e1.A, e2.A };
    const down_inc = Vec3i{ e0.B, e1.B, e2.B };

    const tile_size = tile.dimensions;

    const max_u_f: Float = @floatFromInt(atlas.width - 1);
    const max_v_f: Float = @floatFromInt(atlas.height - 1);

    // P: Main loop
    var y: usize = 0;
    while (y < tile_size) : (y += 1) {
        const z_row_base: usize = y * tile_size; // base addr in z-buffer for row
        const buf_row_base: usize = y * tile_size; // base addr in fb for row

        var w = w_row;

        var x: usize = 0;
        while (x < tile_size) : (x += 1) {
            // Step right (also runs if the z-test fails, thanks to the defer)
            defer w += right_inc;

            if (w[0] + e0.bias >= 0 and w[1] + e1.bias >= 0 and w[2] + e2.bias >= 0) {
                const wf: Vec3f = @floatFromInt(w);
                const den_scaled = (wf[0] * q0 + wf[1] * q1 + wf[2] * q2);
                const inv_z = den_scaled * inv_area;

                const z_idx = z_row_base + x;
                if (inv_z <= tile.z_buf[z_idx]) continue;
                tile.z_buf[z_idx] = inv_z;

                const uv_num = uv0q * @as(Uvf, @splat(wf[0])) +
                    uv1q * @as(Uvf, @splat(wf[1])) +
                    uv2q * @as(Uvf, @splat(wf[2]));

                const rcp_den: Float = 1.0 / den_scaled;
                const uv = uv_num * @as(Uvf, @splat(rcp_den));

                const u_f = std.math.clamp(uv[0], 0.0, max_u_f);
                const v_f = std.math.clamp(uv[1], 0.0, max_v_f);

                const u: usize = @intFromFloat(u_f);
                const v: usize = @intFromFloat(v_f);

                const base: usize = (u + v * atlas.width);
                const argb = atlas.atlas[base];
                tile.buf[buf_row_base + x] = argb;
            }
        }

        // Step down
        w_row += down_inc;
    }
}

////////////////////////////////////////////////////////////////////////////////

const batch_size: usize = 16;

fn tileWorker(
    next: *AtomicUsize,
    triangles: []RasterTriangle,
    tiles_pool: *TilePool,
    buf: Framebuffer,
    tile_offsets: []const usize,
    tile_refs: []const usize,
    atlas: *Atlas,
) void {
    while (true) {
        const tile_base = next.fetchAdd(batch_size, .monotonic);
        if (tile_base >= tiles_pool.count) break;

        for (0..batch_size) |incr| {
            const tile_i = tile_base + incr;
            if (tile_i >= tiles_pool.count) break;

            const start = tile_offsets[tile_i];
            const end = tile_offsets[tile_i + 1];

            if (start == end) continue;

            var t = &tiles_pool.tiles[tile_i];
            t.clear();

            for (tile_refs[start..end]) |tri_i_u| {
                const tri_i: usize = @intCast(tri_i_u);
                renderTriangleInTile(&triangles[tri_i], t, atlas);
            }

            t.write_to_fb(buf);
        }
    }
}

////////////////////////////////////////////////////////////////////////////////

pub const TrianglesRasterizer = struct {
    tile_counts: []usize,
    tile_offsets: []usize,

    /// Per tile write cursor, same as tile_offsets before 2nd pass
    write_pos: []usize,

    /// For all tiles, holds the index of the triangles that overlap
    tile_triangle_indices: []usize,

    pub fn init(
        allocator: std.mem.Allocator,
        tile_count: usize,
    ) !TrianglesRasterizer {
        return .{
            .tile_counts = try allocator.alloc(usize, tile_count),
            .tile_offsets = try allocator.alloc(usize, tile_count + 1),
            .write_pos = try allocator.alloc(usize, tile_count + 1),
            .tile_triangle_indices = try allocator.alloc(usize, 10_000), // initial guess, will grow
        };
    }

    pub fn deinit(self: *TrianglesRasterizer, allocator: std.mem.Allocator) void {
        allocator.free(self.tile_counts);
        allocator.free(self.tile_offsets);
        allocator.free(self.write_pos);
        allocator.free(self.tile_triangle_indices);
    }

    ////

    inline fn tileRangeForTriangle(
        triangle: RasterTriangle,
        tile_dimensions: usize,
        fb_width: usize,
        fb_height: usize,
    ) struct {
        min_tx: usize,
        max_tx: usize,
        min_ty: usize,
        max_ty: usize,
    } {
        const bb = triangle.boundingBox(fb_width, fb_height);

        // WARN: Change to divCeil if it does not work for max
        const min_tx = @divFloor(bb.min_x, tile_dimensions);
        const min_ty = @divFloor(bb.min_y, tile_dimensions);
        const max_tx = std.math.divCeil(usize, bb.max_x, tile_dimensions) catch unreachable;
        const max_ty = std.math.divCeil(usize, bb.max_y, tile_dimensions) catch unreachable;

        // WARN: Clamp to tile grid if necessary

        return .{ .min_tx = min_tx, .max_tx = max_tx, .min_ty = min_ty, .max_ty = max_ty };
    }

    // TODO: Use allocator.realloc instead
    inline fn ensureTileRefsCapacity(
        self: *TrianglesRasterizer,
        allocator: std.mem.Allocator,
        needed: usize,
    ) !void {
        if (self.tile_triangle_indices.len >= needed) return;

        const new_cap = @max(self.tile_triangle_indices.len * 2, needed);
        const new_buf = try allocator.alloc(usize, new_cap);
        allocator.free(self.tile_triangle_indices);
        self.tile_triangle_indices = new_buf;
    }

    pub fn render(
        self: *TrianglesRasterizer,
        allocator: std.mem.Allocator,
        pool: *std.Thread.Pool,
        triangles: []RasterTriangle,
        triangles_per_cube: []usize,
        tile_pool: *TilePool,
        fb: Framebuffer,
        atlas: *Atlas,
    ) !void {
        @memset(self.tile_counts, 0);

        // P: 1st pass, count the triangles for each tile
        for (0..triangles_per_cube.len) |cube_i| { // we work cube-wise
            const count = triangles_per_cube[cube_i];
            if (count == 0) continue;

            const base = cube_i * 12;

            for (triangles[base .. base + count]) |tri| {
                const range = tileRangeForTriangle(tri, tile_pool.tile_dimensions, fb.width, fb.height);

                // NOTE: Try to consider the cache, array is row major, notice the loop order
                var y = range.min_ty;
                while (y < range.max_ty) : (y += 1) {
                    var x = range.min_tx;
                    while (x < range.max_tx) : (x += 1) {
                        const idx = x + tile_pool.count_w * y;
                        self.tile_counts[idx] += 1;
                        tile_pool.tiles[idx].was_occupied = true;
                    }
                }
            }
        }

        var sum: usize = 0;

        for (0..tile_pool.count) |t| {
            self.tile_offsets[t] = sum;
            sum += @as(usize, self.tile_counts[t]);
        }
        self.tile_offsets[tile_pool.count] = sum;

        try self.ensureTileRefsCapacity(allocator, sum);

        // FIX: Change to a memcpy
        for (0..tile_pool.count) |t| self.write_pos[t] = self.tile_offsets[t];

        // P: 2nd pass, scatter triangle indices into tile_refs
        for (0..triangles_per_cube.len) |cube_i| {
            const count = triangles_per_cube[cube_i];
            const base = cube_i * 12;

            for (triangles[base .. base + count], 0..) |tri, tri_i| {
                const range = tileRangeForTriangle(tri, tile_pool.tile_dimensions, fb.width, fb.height);

                var ty = range.min_ty;
                while (ty < range.max_ty) : (ty += 1) {
                    var tx = range.min_tx;
                    while (tx < range.max_tx) : (tx += 1) {
                        const tile_i = tx + tile_pool.count_w * ty;

                        const dst = self.write_pos[tile_i];
                        self.tile_triangle_indices[dst] = @intCast(base + tri_i);
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
            pool.spawnWg(&wg, tileWorker, .{
                &next,
                triangles,
                tile_pool,
                fb,
                self.tile_offsets,
                self.tile_triangle_indices,
                atlas,
            });
        }

        wg.wait();
    }
};
