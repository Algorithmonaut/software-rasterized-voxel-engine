const std = @import("std");
const ctx = @import("context.zig"); // WARN: To refactor
const cfg = @import("config.zig");
const Triangle = @import("triangle.zig").Triangle;
const RasterTriangle = @import("triangle.zig").RasterTriangle;
const tile = @import("tile.zig");
const Framebuffer = @import("Framebuffer.zig").Framebuffer;
const Int = cfg.Int; // WARN: To refactor
const Uint = cfg.Uint;
const Vec4f = cfg.Vec4f;
const Vec3f = cfg.Vec3f;
const Float = cfg.Float;

const FramebufferConfig = @import("engine/EngineConfig.zig").EngineConfig.FramebufferConfig;
pub const cube_count = 100;

const TileRenderJob = struct {
    wg: *std.Thread.WaitGroup,
    renderer: *const Renderer,
    tiles_pool: *tile.TilePool,
    buf: Framebuffer,
    tile_offsets: *const [tile.tiles_count + 1]usize,
    tile_refs: []const cfg.Uint,
    tile_i: usize,

    pub fn run(job: *TileRenderJob) void {
        defer job.wg.finish();

        const tile_i = job.tile_i;
        const start = job.tile_offsets[tile_i];
        const end = job.tile_offsets[tile_i + 1];
        if (start == end) return;

        var t = &job.tiles_pool.tiles[tile_i];
        t.clear();

        for (job.tile_refs[start..end]) |tri_i_u| {
            const tri_i: usize = @intCast(tri_i_u);
            job.renderer.triangles.items[tri_i].render_triangle_in_tile(t);
        }

        t.write_to_fb(job.buf);
    }
};

pub const Renderer = struct {
    triangles: std.ArrayList(RasterTriangle),
    width: usize,
    height: usize,
    tile_dimensions: usize,

    pub fn init(allocator: std.mem.Allocator, conf: FramebufferConfig) !Renderer {
        return .{
            .triangles = try std.ArrayList(RasterTriangle).initCapacity(
                allocator,
                cube_count * 6 * 2,
            ),

            .width = conf.width,
            .height = conf.height,
            .tile_dimensions = conf.tile_dimensions,
        };
    }

    pub fn deinit(self: *Renderer) void {
        _ = self;
    }

    pub fn begin_frame(self: *Renderer, allocator: std.mem.Allocator) !void {
        self.triangles.clearRetainingCapacity();
        try self.triangles.ensureTotalCapacity(allocator, cube_count * 6 * 2);
    }

    inline fn tile_range_for_tri(triangle: RasterTriangle) struct {
        min_tx: usize,
        max_tx: usize,
        min_ty: usize,
        max_ty: usize,
    } {
        const bb = triangle.bounding_box();

        // WARN: Change to divCeil if it does not work for max
        const min_tx = @divFloor(bb.min_x, cfg.tile_dimensions);
        const min_ty = @divFloor(bb.min_y, cfg.tile_dimensions);
        const max_tx = std.math.divCeil(usize, bb.max_x, cfg.tile_dimensions) catch unreachable;
        const max_ty = std.math.divCeil(usize, bb.max_y, cfg.tile_dimensions) catch unreachable;

        // WARN: Clamp to tile grid if necessary

        // return .{
        //         .min_tx = @min(min_tx, tile.tiles_w),
        //         .max_tx_excl = @min(max_tx_excl, tile.tiles_w),
        //         .min_ty = @min(min_ty, tile.tiles_h),
        //         .max_ty_excl = @min(max_ty_excl, tile.tiles_h),
        //     };

        return .{ .min_tx = min_tx, .max_tx = max_tx, .min_ty = min_ty, .max_ty = max_ty };
    }

    pub fn render(
        self: *Renderer,
        pool: *std.Thread.Pool,
        tiles_pool: *tile.TilePool,
        buf: Framebuffer,
        allocator: std.mem.Allocator,
    ) !void {
        // P: First pass (count the triangles for each tile)
        var tile_counts: [tiles_pool.tiles_count]Uint = [_]Uint{0} ** tiles_pool.tiles_count;
        for (self.triangles.items) |triangle| {
            const range = tile_range_for_tri(triangle);

            var x = range.min_tx;
            while (x < range.max_tx) : (x += 1) {
                var y = range.min_ty;
                while (y < range.max_ty) : (y += 1) {
                    tile_counts[x + tiles_pool.tiles_w * y] += 1;
                }
            }
        }

        var tile_offsets: [tiles_pool.tiles_count + 1]usize = undefined;
        var sum: usize = 0;
        for (0..tiles_pool.tiles_count) |t| {
            tile_offsets[t] = sum;
            sum += @as(usize, tile_counts[t]);
        }
        tile_offsets[tiles_pool.tiles_count] = sum;

        var tile_refs = try allocator.alloc(Uint, sum);
        defer allocator.free(tile_refs);

        // Per tile write cursor
        var write_pos: [tiles_pool.tiles_count]usize = undefined;
        for (0..tiles_pool.tiles_count) |t| write_pos[t] = tile_offsets[t];

        // P: Second pass (scatter triangle indices into tile_refs)
        for (self.triangles.items, 0..) |triangle, tri_i| {
            const range = tile_range_for_tri(triangle);

            var tx = range.min_tx;
            while (tx < range.max_tx) : (tx += 1) {
                var ty = range.min_ty;
                while (ty < range.max_ty) : (ty += 1) {
                    const tile_i = tx + tiles_pool.tiles_count_w * ty;

                    const dst = write_pos[tile_i];
                    tile_refs[dst] = @intCast(tri_i);
                    write_pos[tile_i] = dst + 1;
                }
            }
        }

        // Third pass (render per tile and blit) - PARALLEL
        var wg = std.Thread.WaitGroup{};

        // jobs must remain valid until wg.wait() returns
        var jobs = try allocator.alloc(TileRenderJob, tile.tiles_count);
        defer allocator.free(jobs);

        for (0..tiles_pool.tiles_count) |tile_i| {
            const start = tile_offsets[tile_i];
            const end = tile_offsets[tile_i + 1];
            if (start == end) continue; // skip empty tiles

            wg.start();
            jobs[tile_i] = .{
                .wg = &wg,
                .renderer = self,
                .tiles_pool = tiles_pool,
                .buf = buf,
                .tile_offsets = &tile_offsets,
                .tile_refs = tile_refs,
                .tile_i = tile_i,
            };

            try pool.spawn(TileRenderJob.run, .{&jobs[tile_i]});
        }

        wg.wait();
    }

    pub inline fn gen_raster_triangle(self: *const Renderer, tri: *Triangle) ?RasterTriangle {
        const verts = .{ &tri.v0, &tri.v1, &tri.v2 };
        var verts_h: [3]Vec4f = undefined; // verts in homogeneous coordinates
        var rec_ws: Vec3f = undefined; // reciprocal of w = reciprocal of z in camera space

        // P: World -> clip
        inline for (verts, 0..) |vert, i| {
            @prefetch(vert, .{});

            var vert_h = Vec4f{ vert.*[0], vert.*[1], vert.*[2], 1.0 };
            vert_h = ctx.projection_matrix.mul_vec(vert_h);

            const clip_w = vert_h[3];
            const inv_w = 1.0 / clip_w;
            rec_ws[i] = inv_w;
            vert_h = vert_h * @as(Vec4f, @splat(inv_w));

            verts_h[i] = vert_h;
        }

        const v0 = verts_h[0];
        const v1 = verts_h[1];
        const v2 = verts_h[2];

        // P: Basic clipping
        if ((v0[0] > 1 and v1[0] > 1 and v2[0] > 1) or
            v0[0] < -1 and v1[0] < -1 and v2[0] < -1) return null;

        if ((v0[1] > 1 and v1[1] > 1 and v2[1] > 1) or
            v0[1] < -1 and v1[1] < -1 and v2[1] < -1) return null;

        if ((v0[2] > 1 and v1[2] > 1 and v2[2] > 1) or
            v0[2] < 0 or v1[2] < 0 or v2[2] < 0) return null;

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
};
