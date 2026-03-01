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
