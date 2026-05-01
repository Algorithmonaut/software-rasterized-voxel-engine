const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});

pub const Framebuffer = struct {
    base: [*]u8,
    pitch: usize, // bytes per row (maybe aligned)
    width: usize,
    height: usize,

    /// NOTE: Please do not use this shit
    pub inline fn setPixel(self: *const Framebuffer, x: usize, y: usize, color: u32) void {
        const row_ptr: [*]u8 = self.base + @as(usize, @intCast(y)) * self.pitch;
        const row_u32: [*]u32 = @ptrCast(@alignCast(row_ptr));

        row_u32[@as(usize, @intCast(x))] = color;
    }

    pub inline fn getPixel(self: *const Framebuffer, x: usize, y: usize) u32 {
        const row_ptr: [*]u8 = self.base + @as(usize, @intCast(y)) * self.pitch;
        const row_u32: [*]u32 = @ptrCast(@alignCast(row_ptr));

        return row_u32[@as(usize, @intCast(x))];
    }

    pub inline fn getScanline(self: *const Framebuffer, y: usize) [*]u32 {
        const row_ptr: [*]u8 = self.base + @as(usize, @intCast(y)) * self.pitch;
        const row_u32: [*]u32 = @ptrCast(@alignCast(row_ptr));

        return row_u32;
    }

    pub inline fn clearBlack(self: *const Framebuffer) void {
        const row_ptr: [*]u8 = self.base;
        const bytes = self.pitch * self.height;
        @memset(row_ptr[0..bytes], 0);
    }

    pub inline fn clearColor(self: *const Framebuffer, col: u32) void {
        const row_ptr: [*]u8 = self.base;
        const bytes = self.pitch * self.height;

        const pixels: []u32 = std.mem.bytesAsSlice(
            u32,
            @as([]align(@alignOf(u32)) u8, @alignCast(row_ptr[0..bytes])),
        );

        @memset(pixels, col);
    }

    pub inline fn clearGradient(self: *const Framebuffer, sky_rows: []const u32) void {
        std.debug.assert(sky_rows.len >= self.height);
        std.debug.assert(self.pitch % @sizeOf(u32) == 0);

        const row_pixel_count = self.pitch / @sizeOf(u32);

        for (0..self.height) |y| {
            const row_offset = y * self.pitch;

            const row_bytes_unaligned: []u8 =
                self.base[row_offset .. row_offset + self.pitch];

            const row_bytes: []align(@alignOf(u32)) u8 =
                @alignCast(row_bytes_unaligned);

            const row_pixels: []u32 =
                std.mem.bytesAsSlice(u32, row_bytes);

            std.debug.assert(row_pixels.len == row_pixel_count);

            @memset(row_pixels, sky_rows[y]);
        }
    }

    pub fn drawLine(
        self: *Framebuffer,
        x0_in: i32,
        y0_in: i32,
        x1_in: i32,
        y1_in: i32,
        color: u32,
    ) void {
        var x0 = x0_in;
        var y0 = y0_in;
        const x1 = x1_in;
        const y1 = y1_in;

        const width_i32: i32 = @intCast(self.width);
        const height_i32: i32 = @intCast(self.height);

        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = @intCast(@abs(y1 - y0));

        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;

        var err: i32 = dx - dy;

        while (true) {
            if (x0 >= 0 and x0 < width_i32 and y0 >= 0 and y0 < height_i32) {
                self.setPixel(@intCast(x0), @intCast(y0), color);
            }

            if (x0 == x1 and y0 == y1) break;

            const e2: i32 = err * 2;

            if (e2 > -dy) {
                err -= dy;
                x0 += sx;
            }

            if (e2 < dx) {
                err += dx;
                y0 += sy;
            }
        }
    }

    pub fn drawLineBold(
        self: *Framebuffer,
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
        thickness: i32,
        color: u32,
    ) void {
        if (thickness <= 1) {
            self.drawLine(x0, y0, x1, y1, color);
            return;
        }

        const dx: i32 = x1 - x0;
        const dy: i32 = y1 - y0;

        const half: i32 = @divTrunc(thickness, 2);

        if (@abs(dx) >= @abs(dy)) {
            var o: i32 = -half;
            while (o <= half) : (o += 1) {
                self.drawLine(x0, y0 + o, x1, y1 + o, color);
            }
        } else {
            var o: i32 = -half;
            while (o <= half) : (o += 1) {
                self.drawLine(x0 + o, y0, x1 + o, y1, color);
            }
        }
    }

    pub inline fn set_pixel_blend(
        self: *const Framebuffer,
        x: usize,
        y: usize,
        src_col: u32,
    ) void {
        const dst_col = self.getPixel(x, y);

        const a: u8 = @truncate((src_col >> 24));
        if (a == 0) return;
        if (a == 0xFF) {
            self.setPixel(x, y, src_col);
            return;
        }

        const inv_a: u8 = 0xFF - a;

        const sr: u8 = @truncate((src_col >> 16));
        const sg: u8 = @truncate((src_col >> 8));
        const sb: u8 = @truncate((src_col));

        const dr: u8 = @truncate((dst_col >> 16));
        const dg: u8 = @truncate((dst_col >> 8));
        const db: u8 = @truncate((dst_col));

        // Blend each channel
        // We shift by 8 as a fast approx to divide by 255
        const a32: u32 = a;
        const ia32: u32 = inv_a;

        const r: u32 = ((@as(u32, sr) * a32) + (@as(u32, dr) * ia32)) >> 8;
        const g: u32 = ((@as(u32, sg) * a32) + (@as(u32, dg) * ia32)) >> 8;
        const b: u32 = ((@as(u32, sb) * a32) + (@as(u32, db) * ia32)) >> 8;

        const argb: u32 = (0xFF << 24) | (r << 16) | (g << 8) | b;

        self.setPixel(x, y, argb);
    }
};
