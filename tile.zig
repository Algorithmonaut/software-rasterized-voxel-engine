const cfg = @import("config.zig");
const Float = cfg.Float;
const std = @import("std");
const Framebuffer = @import("Framebuffer.zig").Framebuffer;
const FramebufferConfig = @import("EngineConfig.zig").EngineConfig.FramebufferConfig;

pub const Tile = struct {
    z_buf: []Float,
    buf: []u32,
    pos: [2]usize,
    was_occupied: bool,

    pub fn init(allocator: std.mem.Allocator, x: usize, y: usize, size: usize) !Tile {
        return .{
            .z_buf = try allocator.alloc(Float, size * size),
            .buf = try allocator.alloc(u32, size * size),
            .pos = .{ x, y },
            .was_occupied = false,
        };
    }

    pub fn clear(self: *Tile) void {
        const buf_slice = self.buf[0..];
        const z_buf_slice = self.z_buf[0..];
        @memset(buf_slice, 0);
        @memset(z_buf_slice, -std.math.floatMax(Float));
    }

    pub fn write_to_fb(self: *Tile, buf: Framebuffer) void {
        const x0 = self.pos[0];
        const y0 = self.pos[1];

        const copy_w: usize = @min(cfg.tile_dimensions, cfg.width - x0);
        const copy_h: usize = @min(cfg.tile_dimensions, cfg.height - y0);

        var y: usize = 0;
        while (y < copy_h) : (y += 1) {
            const src = self.buf[y * cfg.tile_dimensions .. y * cfg.tile_dimensions + copy_w];
            const dst = buf.get_scanline(y0 + y)[x0 .. x0 + copy_w];
            @memcpy(dst, src);
        }
    }
};

pub const TilePool = struct {
    tiles: []Tile,
    tiles_count_w: usize,
    tiles_count_h: usize,
    tiles_count: usize,
    tile_dimensions: usize,

    pub fn init(allocator: std.mem.Allocator, conf: FramebufferConfig) !TilePool {
        const tiles_count_w = try std.math.divCeil(usize, conf.width, conf.tile_dimensions);
        const tiles_count_h = try std.math.divCeil(usize, conf.height, conf.tile_dimensions);
        const tiles_count = tiles_count_w * tiles_count_h;
        const tile_dimensions = conf.tile_dimensions;

        var tiles = try allocator.alloc(Tile, tiles_count);
        for (0..tiles_count) |i| {
            const x_pos = (i % tiles_count_w) * tile_dimensions;
            const y_pos = (i / tiles_count_w) * tile_dimensions;
            tiles[i] = try Tile.init(allocator, x_pos, y_pos, conf.tile_dimensions);
        }

        return .{
            .tiles = tiles,
            .tiles_count_w = tiles_count_w,
            .tiles_count_h = tiles_count_h,
            .tiles_count = tiles_count,
            .tile_dimensions = conf.tile_dimensions,
        };
    }

    pub fn debug_show_tiles_border(self: *TilePool, buf: Framebuffer) void {
        const color: u32 = 0xF0FF0000;
        for (self.tiles) |*tile| {
            if (tile.was_occupied) {
                const x0 = tile.pos[0] + 2;
                const y0 = tile.pos[1] + 2;

                const x1 = @min(x0 + self.tile_dimensions - 1, cfg.width - 1) - 2;
                const y1 = @min(y0 + self.tile_dimensions - 1, cfg.height - 1) - 2;

                // Top/bottom edge
                var x: usize = x0;
                while (x <= x1) : (x += 1) {
                    buf.set_pixel_blend(x, y0, color);
                    buf.set_pixel_blend(x, y1, color);
                }

                // Left/bottom edge (skip y0 & y1 to avoid double-blending top corners)
                var y: usize = y0 + 1;
                while (y < y1) : (y += 1) {
                    buf.set_pixel_blend(x0, y, color);
                    buf.set_pixel_blend(x1, y, color);
                }

                tile.was_occupied = false; // FIX: prob not clean to put this here
            }
        }
    }
};
