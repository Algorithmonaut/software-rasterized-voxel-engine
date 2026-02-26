const cfg = @import("config.zig");
const size = cfg.tile_dimensions;
const Float = cfg.float;
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
};

const tiles_w = std.math.divCeil(usize, cfg.width, size) catch unreachable;
const tiles_h = std.math.divCeil(usize, cfg.height, size) catch unreachable;
const tiles_count = tiles_w * tiles_h;

pub const TilePool = struct {
    tiles: [tiles_count]Tile,

    pub fn init() TilePool {
        var tiles: [tiles_count]Tile = undefined;
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

        for (&self.tiles) |*tile| {
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
