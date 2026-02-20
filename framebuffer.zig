const std = @import("std");
const cfg = @import("config.zig");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const float = cfg.float;

pub const Framebuffer = struct {
    base: [*]u8, // ptr to the first byte of pixels
    pitch: usize, // bytes per row (maybe aligned)
    z_buffer: []float,

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

    inline fn clear_black(self: *const Framebuffer) void {
        const row_ptr: [*]u8 = self.base;
        // const bpp: usize = 4; // bytes per pixel for ARGB8888
        const bytes = self.pitch * cfg.height;
        @memset(row_ptr[0..bytes], 0);
    }

    // NOTE: Big hit on performances compared to clear()
    inline fn clear(self: *const Framebuffer, color: u32) void {
        const bytes = self.pitch * cfg.height;
        const words = std.mem.bytesAsSlice(u32, self.base[0..bytes]);
        @memset(words, color);
    }

    inline fn clear_z(self: *const Framebuffer) void {
        const z_slice = self.z_buffer[0..];
        @memset(z_slice, -std.math.inf(float));
    }

    pub inline fn clear_all(self: *const Framebuffer) void {
        clear_black(self);
        clear_z(self);
    }
};
