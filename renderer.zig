const std = @import("std");
const cfg = @import("config.zig");
const tri = @import("triangle.zig");
const tile = @import("tile.zig");
const fb = @import("framebuffer.zig");
const Int = cfg.Int;
const Uint = cfg.Uint;

pub const cube_count = 3;

const TileRenderJob = struct {
    wg: *std.Thread.WaitGroup,
    renderer: *const Renderer,
    tiles_pool: *tile.TilePool,
    buf: fb.Framebuffer,
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
    triangles: std.ArrayList(tri.RasterTriangle),

    pub fn init(allocator: std.mem.Allocator) !Renderer {
        return .{
            .triangles = try std.ArrayList(tri.RasterTriangle).initCapacity(
                allocator,
                cube_count * 6 * 2,
            ),
        };
    }

    pub fn begin_frame(self: *Renderer, allocator: std.mem.Allocator) !void {
        self.triangles.clearRetainingCapacity();
        try self.triangles.ensureTotalCapacity(allocator, cube_count * 6 * 2);
    }

    inline fn tile_range_for_tri(triangle: tri.RasterTriangle) struct {
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
        buf: fb.Framebuffer,
        allocator: std.mem.Allocator,
    ) !void {
        // P: First pass (count the triangles for each tile)
        var tile_counts: [tile.tiles_count]Uint = [_]Uint{0} ** tile.tiles_count;
        for (self.triangles.items) |triangle| {
            const range = tile_range_for_tri(triangle);

            var x = range.min_tx;
            while (x < range.max_tx) : (x += 1) {
                var y = range.min_ty;
                while (y < range.max_ty) : (y += 1) {
                    tile_counts[x + tile.tiles_w * y] += 1;
                }
            }
        }

        var i: usize = 0;
        while (i < tile_counts.len) : (i += 1) {
            if (tile_counts[i] > 0) {
                tiles_pool.tiles[i].debug_show_tiles_border_green(buf);
            }
        }

        var tile_offsets: [tile.tiles_count + 1]usize = undefined;
        var sum: usize = 0;
        for (0..tile.tiles_count) |t| {
            tile_offsets[t] = sum;
            sum += @as(usize, tile_counts[t]);
        }
        tile_offsets[tile.tiles_count] = sum;

        var tile_refs = try allocator.alloc(Uint, sum);

        // Per tile write cursor
        var write_pos: [tile.tiles_count]usize = undefined;
        for (0..tile.tiles_count) |t| write_pos[t] = tile_offsets[t];

        // P: Second pass (scatter triangle indices into tile_refs)
        for (self.triangles.items, 0..) |triangle, tri_i| {
            const range = tile_range_for_tri(triangle);

            var tx = range.min_tx;
            while (tx < range.max_tx) : (tx += 1) {
                var ty = range.min_ty;
                while (ty < range.max_ty) : (ty += 1) {
                    const tile_i = tx + tile.tiles_w * ty;

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

        for (0..tile.tiles_count) |tile_i| {
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
};
