const std = @import("std");
const cfg = @import("config.zig");
const Framebuffer = @import("Framebuffer.zig").Framebuffer;

pub const BlockTypes = enum(usize) {
    dirt = 0,
    stone = 1,
    grass = 2,
};

pub const Atlas = struct {
    atlas: [cfg.atlas_size]u32,

    pub fn init() !Atlas {
        const cwd = std.fs.cwd();
        var dir = try cwd.openDir("tex/", .{});
        defer dir.close();
        var file = try dir.openFile("atlas.rgb", .{ .mode = .read_only });
        defer file.close();

        var read_buf: [cfg.atlas_size_rgb]u8 = undefined;
        var file_reader = file.reader(&read_buf);
        const reader = &file_reader.interface;

        var rgb: [cfg.atlas_size_rgb]u8 = undefined;
        try reader.readSliceAll(&rgb);

        // Ensure there is not trailing data
        var extra: [1]u8 = undefined;
        const m = try reader.readSliceShort(&extra);
        if (m != 0) return error.UnexpectedTrailingData;

        var argb: [cfg.atlas_size]u32 = undefined;
        var i: usize = 0;
        var p: usize = 0;
        while (i < rgb.len) : (i += 3) {
            argb[p] = @as(u32, rgb[i]) << 16 |
                @as(u32, rgb[i + 1]) << 8 |
                @as(u32, rgb[i + 2]);

            p += 1;
        }

        return .{
            .atlas = argb,
        };
    }

    pub fn debug_show_atlas(self: *const Atlas, buf: *Framebuffer) void {
        var y: usize = 0;
        while (y < cfg.atlas_h) : (y += 1) {
            const base_addr_src = y * cfg.atlas_w;

            const src = self.atlas[base_addr_src .. base_addr_src + cfg.atlas_w];
            const dst = buf.get_scanline(y)[0..cfg.atlas_w];
            @memcpy(dst, src);
        }
    }
};
