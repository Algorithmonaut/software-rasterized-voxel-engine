const cfg = @import("config.zig");
const size = cfg.tile_dimensions;
const Float = cfg.Float;
const std = @import("std");
const fb = @import("framebuffer.zig");

pub const Tile = struct {
    z_buf: [size * size]Float,
    buf: [size * size]u32,
    pos: [2]usize,

    pub fn init(x: usize, y: usize) Tile {
        return .{
            .z_buf = undefined,
            .buf = undefined,
            .pos = .{ x, y },
        };
    }

    pub fn debug_show_tiles_border_green(self: *Tile, buf: fb.Framebuffer) void {
        const color: u32 = 0xFF007F00;

        const x0 = self.pos[0];
        const y0 = self.pos[1];

        const x1 = @min(x0 + size - 1, cfg.width - 1);
        const y1 = @min(y0 + size - 1, cfg.height - 1);

        // Top/bottom edges
        var x: usize = x0;
        while (x <= x1) : (x += 1) {
            buf.set_pixel(x, y0, color);
            buf.set_pixel(x, y1, color);
        }

        // Left/right edges
        var y: usize = y0;
        while (y <= y1) : (y += 1) {
            buf.set_pixel(x0, y, color);
            buf.set_pixel(x1, y, color);
        }
    }

    pub fn clear(self: *Tile) void {
        const buf_slice = self.buf[0..];
        const z_buf_slice = self.z_buf[0..];
        @memset(buf_slice, 0);
        @memset(z_buf_slice, -std.math.floatMax(Float));
    }

    pub fn write_to_fb(self: *Tile, buf: fb.Framebuffer) void {
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

pub const tiles_w = std.math.divCeil(usize, cfg.width, size) catch unreachable;
pub const tiles_h = std.math.divCeil(usize, cfg.height, size) catch unreachable;
pub const tiles_count = tiles_w * tiles_h;

pub const TilePool = struct {
    tiles: []Tile,

    pub fn init(allocator: std.mem.Allocator) !TilePool {
        var tiles = try allocator.alloc(Tile, tiles_count);
        for (0..tiles_count) |i| {
            const x_pos = (i % tiles_w) * size;
            const y_pos = (i / tiles_w) * size;
            tiles[i] = Tile.init(x_pos, y_pos);
        }

        return .{
            .tiles = tiles,
        };
    }

    pub fn debug_show_tiles_border(self: *TilePool, buf: fb.Framebuffer) void {
        const color: u32 = 0xFF7F0000;

        for (self.tiles) |tile| {
            const x0 = tile.pos[0];
            const y0 = tile.pos[1];

            const x1 = @min(x0 + size - 1, cfg.width - 1);
            const y1 = @min(y0 + size - 1, cfg.height - 1);

            // Top edge
            var x: usize = x0;
            while (x <= x1) : (x += 1) {
                buf.set_pixel(x, y0, color);
            }

            // Left edge
            var y: usize = y0;
            while (y <= y1) : (y += 1) {
                buf.set_pixel(x0, y, color);
            }
        }
    }
};
