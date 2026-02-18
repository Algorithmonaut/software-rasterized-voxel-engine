const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});

pub const Framebuffer = struct {
    base: [*]u8, // ptr to the first byte of pixels
    pitch: usize, // bytes per row (maybe aligned)
    width: usize,
    height: usize,
    z_buffer: [960 * 540]f32,

    pub inline fn set_pixel(self: *const Framebuffer, x: usize, y: usize, color: u32) void {
        // NOTE: Bounds check, remove for max speed
        // std.debug.assert(x < self.width and y < self.height);

        const row_ptr: [*]u8 = self.base + @as(usize, @intCast(y)) * self.pitch;
        const row_u32: [*]u32 = @ptrCast(@alignCast(row_ptr));

        row_u32[@as(usize, @intCast(x))] = color;
    }

    pub inline fn get_scanline(self: *const Framebuffer, y: usize) [*]u32 {
        const row_ptr: [*]u8 = self.base + @as(usize, @intCast(y)) * self.pitch;
        const row_u32: [*]u32 = @ptrCast(@alignCast(row_ptr));

        return row_u32;
    }

    pub inline fn clear(self: *const Framebuffer, color: u32) void {
        // bytes per pixel for ARGB8888
        const bpp: usize = 4;
        const row_bytes = self.width * bpp;

        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            const row_ptr: [*]u8 = self.base + y * self.pitch;

            // Clear whole row in bytes first (fast path for color==0)
            if (color == 0) {
                @memset(row_ptr[0..row_bytes], 0);
            } else {
                // Treat row as u32 pixels
                const row_u32: [*]u32 = @ptrCast(@alignCast(row_ptr));
                @memset(row_u32[0..self.width], color);
            }
        }
    }

    pub inline fn clear_z(self: *Framebuffer) void {
        const neg_inf: f32 = -std.math.inf(f32);
        @memset(self.z_buffer[0..], neg_inf);
    }
};
