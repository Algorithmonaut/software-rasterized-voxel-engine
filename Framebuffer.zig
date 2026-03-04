const std = @import("std");
const cfg = @import("config.zig");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});

pub const Framebuffer = struct {
    base: [*]u8, // ptr to the first byte of pixels
    pitch: usize, // bytes per row (maybe aligned)

    /// NOTE: Please do not use this shit
    pub inline fn set_pixel(self: *const Framebuffer, x: usize, y: usize, color: u32) void {
        const row_ptr: [*]u8 = self.base + @as(usize, @intCast(y)) * self.pitch;
        const row_u32: [*]u32 = @ptrCast(@alignCast(row_ptr));

        row_u32[@as(usize, @intCast(x))] = color;
    }

    pub inline fn get_pixel(self: *const Framebuffer, x: usize, y: usize) u32 {
        const row_ptr: [*]u8 = self.base + @as(usize, @intCast(y)) * self.pitch;
        const row_u32: [*]u32 = @ptrCast(@alignCast(row_ptr));

        return row_u32[@as(usize, @intCast(x))];
    }

    pub inline fn set_pixel_blend(
        self: *const Framebuffer,
        x: usize,
        y: usize,
        src_col: u32,
    ) void {
        const dst_col = self.get_pixel(x, y);

        const a: u8 = @truncate((src_col >> 24));
        if (a == 0) return;
        if (a == 0xFF) {
            self.set_pixel(x, y, src_col);
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

        self.set_pixel(x, y, argb);
    }

    pub inline fn get_scanline(self: *const Framebuffer, y: usize) [*]u32 {
        const row_ptr: [*]u8 = self.base + @as(usize, @intCast(y)) * self.pitch;
        const row_u32: [*]u32 = @ptrCast(@alignCast(row_ptr));

        return row_u32;
    }

    pub inline fn clear_black(self: *const Framebuffer) void {
        const row_ptr: [*]u8 = self.base;
        const bytes = self.pitch * cfg.height;
        @memset(row_ptr[0..bytes], 0);
    }
};
