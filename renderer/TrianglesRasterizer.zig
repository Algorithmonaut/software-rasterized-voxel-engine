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

const types = @import("../math/types.zig");
const Vec2fx = types.Vec2fx;
const SUBPIXEL_BITS = types.SUBPIXEL_BITS;
const SUBPIXEL_SCALE = types.SUBPIXEL_SCALE;
const HALF_SUBPIXEL = types.HALF_SUBPIXEL;

const Uvf = @Vector(2, Float);
const Vec2i = @Vector(2, i32);

/////// NEW IMPL

const step_x_size = 8;
const step_y_size = 1;

const I8 = @Vector(8, i32);
const F8 = @Vector(8, f32);

// FIX: TEMPORARY FIX use i64 for triangles that intersect the near plane
// to be rendered properly, later change to i32 but consider origin at raster center
pub const Edge = struct {
    // Edge function can be refactored: E(x,y) = Ax + By + C with A B C constants
    A: i32,
    B: i32,
    C: i32, // WARN: Change to i64 if overflow

    top_left_bias: i32,
    cons_bias: i32, // conservative offset used to mitigate T-junctions cracks

    /// Evaluate the point (x, y) against the edge
    inline fn eval(self: Edge, x: i32, y: i32) i32 {
        return self.A * x + self.B * y + self.C;
    }
};

inline fn makeEdge(a: @Vector(2, i32), b: @Vector(2, i32)) Edge {
    const x0 = a[0];
    const y0 = a[1];
    const x1 = b[0];
    const y1 = b[1];
    const dy = y1 - y0;
    const dx = x1 - x0;

    const is_top_left: bool = (dy > 0) or (dy == 0 and dx < 0);

    const eA = y1 - y0;
    const eB = x0 - x1;

    // const px = 1;

    const tx: i32 = if (eA >= 0) 1 else 0;
    const ty: i32 = if (eB >= 0) 1 else 0;

    // E(x,y) = (y1 - y0)*x + (x0 - x1)*y + (y0*x1 - x0*y1)
    return .{
        .A = eA,
        .B = eB,
        .C = y0 * x1 - x0 * y1,
        .top_left_bias = if (is_top_left) 0 else -1,
        .cons_bias = eA * tx + eB * ty,
    };
}

inline fn renderTriangleInTile(
    triangle: *const RasterTriangle,
    tile: *Tile,
    atlas: *Atlas,
    render_wireframe: bool,
) void {
    const e0 = triangle.e0;
    const e1 = triangle.e1;
    const e2 = triangle.e2;

    const area = triangle.area;
    if (area == 0) return; // triangle is degenerate

    const inv_area = triangle.inv_area;

    // const tx0: i32 = @intCast(tile.pos[0]);
    // const ty0: i32 = @intCast(tile.pos[1]);
    const tx0_fx: i32 = (@as(i32, @intCast(tile.pos[0])) << SUBPIXEL_BITS) + HALF_SUBPIXEL;
    const ty0_fx: i32 = (@as(i32, @intCast(tile.pos[1])) << SUBPIXEL_BITS) + HALF_SUBPIXEL;

    const tile_size = tile.dimensions;

    // P: Edge values at tile origin, without fill-rule bias
    const w0_origin: i32 = e0.eval(tx0_fx, ty0_fx);
    const w1_origin: i32 = e1.eval(tx0_fx, ty0_fx);
    const w2_origin: i32 = e2.eval(tx0_fx, ty0_fx);

    // P: Integer edge stepping FOR coverage
    const px_step: i32 = 1 << SUBPIXEL_BITS; // 16
    const right_inc = Vec3i{ e0.A * px_step, e1.A * px_step, e2.A * px_step };
    const down_inc = Vec3i{ e0.B * px_step, e1.B * px_step, e2.B * px_step };

    var w_row = Vec3i{ w0_origin, w1_origin, w2_origin };

    // P: Reciprocal depth at vertices.
    const q0: Float = triangle.q0;
    const q1: Float = triangle.q1;
    const q2: Float = triangle.q2;

    // P: Wireframe thickness
    const avg_rec_depth: Float = (q0 + q1 + q2) / 3.0;
    const base_thickness: Float = @floatFromInt(50000 << SUBPIXEL_BITS);
    const thickness: i32 = @intFromFloat(base_thickness * avg_rec_depth);

    // P: Attribute values multiplied by reciprocal depth
    const uv0: Uvf = triangle.uv0;
    const uv1: Uvf = triangle.uv1;
    const uv2: Uvf = triangle.uv2;

    const uq0: Float = uv0[0] * q0;
    const uq1: Float = uv1[0] * q1;
    const uq2: Float = uv2[0] * q2;

    const vq0: Float = uv0[1] * q0;
    const vq1: Float = uv1[1] * q1;
    const vq2: Float = uv2[1] * q2;

    // P: Evaluate depth/uv interpolants once at tile origin
    // This is a 'base' for incremental stepping
    const w0_origin_f: Float = @floatFromInt(w0_origin);
    const w1_origin_f: Float = @floatFromInt(w1_origin);
    const w2_origin_f: Float = @floatFromInt(w2_origin);

    // den_row is both the denominator of attribute interpolation
    // and the numerator of depth interpolation
    var den_row: Float = w0_origin_f * q0 + w1_origin_f * q1 + w2_origin_f * q2;
    var u_num_row: Float = w0_origin_f * uq0 + w1_origin_f * uq1 + w2_origin_f * uq2;
    var v_num_row: Float = w0_origin_f * vq0 + w1_origin_f * vq1 + w2_origin_f * vq2;

    // P: Incremental values (constant x/y derivatives) FOR depth/uv
    const e0_a_f: Float = @floatFromInt(e0.A);
    const e1_a_f: Float = @floatFromInt(e1.A);
    const e2_a_f: Float = @floatFromInt(e2.A);
    const e0_b_f: Float = @floatFromInt(e0.B);
    const e1_b_f: Float = @floatFromInt(e1.B);
    const e2_b_f: Float = @floatFromInt(e2.B);

    const px_step_f: Float = @floatFromInt(1 << SUBPIXEL_BITS);

    const den_dx: Float = (e0_a_f * q0 + e1_a_f * q1 + e2_a_f * q2) * px_step_f;
    const den_dy: Float = (e0_b_f * q0 + e1_b_f * q1 + e2_b_f * q2) * px_step_f;

    const u_num_dx: Float = (e0_a_f * uq0 + e1_a_f * uq1 + e2_a_f * uq2) * px_step_f;
    const u_num_dy: Float = (e0_b_f * uq0 + e1_b_f * uq1 + e2_b_f * uq2) * px_step_f;

    const v_num_dx: Float = (e0_a_f * vq0 + e1_a_f * vq1 + e2_a_f * vq2) * px_step_f;
    const v_num_dy: Float = (e0_b_f * vq0 + e1_b_f * vq1 + e2_b_f * vq2) * px_step_f;

    // P: Stepping
    var y: usize = 0;
    while (y < tile_size) : (y += 1) {
        const row_base: usize = y * tile_size;

        // Top-left rule and T-junction bias
        var w = w_row + Vec3i{
            e0.top_left_bias + e0.cons_bias,
            e1.top_left_bias + e1.cons_bias,
            e2.top_left_bias + e2.cons_bias,
        };

        var den: Float = den_row;
        var u_num: Float = u_num_row;
        var v_num: Float = v_num_row;

        var x: usize = 0;
        while (x < tile_size) : (x += 1) {
            defer {
                w += right_inc;
                den += den_dx;
                u_num += u_num_dx;
                v_num += v_num_dx;
            }

            if ((w[0] | w[1] | w[2]) < 0) continue;

            if (render_wireframe) {
                const w_thick = w - @as(Vec3i, @splat(thickness));
                if ((w_thick[0] | w_thick[1] | w_thick[2]) >= 0) continue;
            }

            const inv_z: Float = den * inv_area;
            const idx: usize = row_base + x;

            if (inv_z <= tile.z_buf[idx]) continue;
            tile.z_buf[idx] = inv_z;

            const rcp_den: Float = 1.0 / den;

            // const u_f = std.math.clamp(u_num * rcp_den, 0.0, max_u_f);
            // const v_f = std.math.clamp(v_num * rcp_den, 0.0, max_v_f);

            const size_f: Float = @floatFromInt(triangle.tex_tile_size);
            const u_wrap = @mod(u_num * rcp_den, size_f);
            const v_wrap = @mod(v_num * rcp_den, size_f);

            const u_tile = std.math.clamp(
                @as(usize, @intFromFloat(u_wrap)),
                0,
                triangle.tex_tile_size - 1,
            );
            const v_tile = std.math.clamp(
                @as(usize, @intFromFloat(v_wrap)),
                0,
                triangle.tex_tile_size - 1,
            );

            const u: usize = triangle.tex_u + u_tile;
            const v: usize = triangle.tex_v + v_tile;

            const tex_idx: usize = u + v * atlas.width;
            tile.buf[idx] = atlas.atlas[tex_idx];
        }

        w_row += down_inc;
        den_row += den_dy;
        u_num_row += u_num_dy;
        v_num_row += v_num_dy;
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
    render_wireframe: bool,
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
                renderTriangleInTile(&triangles[tri_i], t, atlas, render_wireframe);
            }

            t.write_to_fb(buf);
        }
    }
}

////////////////////////////////////////////////////////////////////////////////

inline fn triangleMayOverlapTile(tri: *const RasterTriangle, tile: *const Tile) bool {
    const e0 = tri.e0;
    const e1 = tri.e1;
    const e2 = tri.e2;

    const x0: i32 = @intCast(tile.pos[0] << SUBPIXEL_BITS);
    const y0: i32 = @intCast(tile.pos[1] << SUBPIXEL_BITS);
    const x1: i32 = @intCast((tile.pos[0] + tile.dimensions) << SUBPIXEL_BITS);
    const y1: i32 = @intCast((tile.pos[1] + tile.dimensions) << SUBPIXEL_BITS);

    const tl = Vec2i{ x0, y0 };
    const tr = Vec2i{ x1, y0 };
    const bl = Vec2i{ x0, y1 };
    const br = Vec2i{ x1, y1 };

    const e0_outside =
        e0.eval(tl[0], tl[1]) < 0 and
        e0.eval(tr[0], tr[1]) < 0 and
        e0.eval(bl[0], bl[1]) < 0 and
        e0.eval(br[0], br[1]) < 0;

    const e1_outside =
        e1.eval(tl[0], tl[1]) < 0 and
        e1.eval(tr[0], tr[1]) < 0 and
        e1.eval(bl[0], bl[1]) < 0 and
        e1.eval(br[0], br[1]) < 0;

    const e2_outside =
        e2.eval(tl[0], tl[1]) < 0 and
        e2.eval(tr[0], tr[1]) < 0 and
        e2.eval(bl[0], bl[1]) < 0 and
        e2.eval(br[0], br[1]) < 0;

    return !(e0_outside or e1_outside or e2_outside);
}

pub const TrianglesRasterizer = struct {
    tile_counts: []usize,
    tile_offsets: []usize,

    /// Per tile write cursor, same as tile_offsets before 2nd pass
    write_pos: []usize,

    /// For all tiles, holds the index of the triangles that overlap
    tile_triangle_indices: []usize,

    render_wireframe: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        tile_count: usize,
    ) !TrianglesRasterizer {
        return .{
            .tile_counts = try allocator.alloc(usize, tile_count),
            .tile_offsets = try allocator.alloc(usize, tile_count + 1),
            .write_pos = try allocator.alloc(usize, tile_count + 1),
            .tile_triangle_indices = try allocator.alloc(usize, 10_000), // initial guess, will grow

            .render_wireframe = false,
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
        tile_pool: *TilePool,
        fb: Framebuffer,
        atlas: *Atlas,
    ) !void {
        @memset(self.tile_counts, 0);

        // TODO: A lot of these properties are shared between the
        // two quad's triangles, set them there

        // P: Set the properties of triangles, idk if I should multithread
        for (triangles) |*tri| {
            const a = tri.v0;
            const b = tri.v1;
            const c = tri.v2;

            tri.e0 = makeEdge(b, c);
            tri.e1 = makeEdge(c, a);
            tri.e2 = makeEdge(a, b);
            tri.area = tri.e0.eval(a[0], a[1]);
            tri.inv_area = 1 / @as(Float, @floatFromInt(tri.area));
        }

        // P: 1st pass, count the triangles for each tile
        for (0..triangles.len) |tri_i| {
            const tri = triangles[tri_i];
            const range = tileRangeForTriangle(tri, tile_pool.tile_dimensions, fb.width, fb.height);

            // NOTE: Try to consider the cache, array is row major, notice the loop order
            var y = range.min_ty;
            while (y < range.max_ty) : (y += 1) {
                var x = range.min_tx;
                while (x < range.max_tx) : (x += 1) {
                    const idx = x + tile_pool.count_w * y;
                    const tile = &tile_pool.tiles[idx];
                    if (!triangleMayOverlapTile(&tri, tile)) continue;
                    self.tile_counts[idx] += 1;
                    tile.was_occupied = true;
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
        for (0..triangles.len) |tri_i| { // we work cube-wise
            const tri = triangles[tri_i];
            const range = tileRangeForTriangle(tri, tile_pool.tile_dimensions, fb.width, fb.height);

            var ty = range.min_ty;
            while (ty < range.max_ty) : (ty += 1) {
                var tx = range.min_tx;
                while (tx < range.max_tx) : (tx += 1) {
                    const tile_i = tx + tile_pool.count_w * ty;
                    if (!triangleMayOverlapTile(&tri, &tile_pool.tiles[tile_i])) continue;

                    const dst = self.write_pos[tile_i];
                    self.tile_triangle_indices[dst] = @intCast(tri_i);
                    self.write_pos[tile_i] = dst + 1;
                }
            }
        }

        // P: Third pass (render per tile and blit) - PARALLEL
        var next = AtomicUsize.init(0);
        var wg = std.Thread.WaitGroup{};
        const worker_count = (try std.Thread.getCpuCount()) - 1;

        for (0..worker_count) |_| {
            pool.spawnWg(&wg, tileWorker, .{
                &next,
                triangles,
                tile_pool,
                fb,
                self.tile_offsets,
                self.tile_triangle_indices,
                atlas,
                self.render_wireframe,
            });
        }

        wg.wait();
    }
};
