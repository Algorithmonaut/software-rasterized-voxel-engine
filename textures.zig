const std = @import("std");
const fb = @import("framebuffer.zig");

pub const atlas_w = 96;
pub const atlas_h = 48;
pub const tex_w = 16;
pub const tex_h = 16;
pub const channels = 3;
pub const full_size = atlas_w * atlas_h * channels;

pub const BlockTypes = enum(usize) {
    dirt = 1,
    stone = 2,
    grass = 3,
};

pub const Atlas = struct {
    atlas: [full_size]u8,

    pub fn init() !Atlas {
        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        const io = threaded.io();

        const cwd = std.Io.Dir.cwd();
        const dir = try cwd.openDir(io, "tex/", .{});
        defer dir.close(io);
        var file = try dir.openFile(io, "atlas.rgb", .{ .mode = .read_only });
        defer file.close(io);

        var read_buf: [full_size]u8 = undefined;
        var file_reader = file.reader(io, &read_buf);
        const reader = &file_reader.interface;

        var rgb: [full_size]u8 = undefined;
        try reader.readSliceAll(&rgb);

        // Ensure there is not trailing data
        var extra: [1]u8 = undefined;
        const m = try reader.readSliceShort(&extra);
        if (m != 0) return error.UnexpectedTrailingData;

        return .{
            .atlas = rgb,
        };
    }

    pub fn debug_show_atlas(self: *const Atlas, buf: *fb.Framebuffer) void {
        var i: usize = 0;
        while (i < atlas_w) : (i += 1) {
            var j: usize = 0;
            while (j < atlas_h) : (j += 1) {
                const base_addr = i * channels + j * channels * atlas_w;
                const r = self.atlas[base_addr];
                const g = self.atlas[base_addr + 1];
                const b = self.atlas[base_addr + 2];

                const xrgb: u32 = @as(u32, 0xFF) << 24 |
                    @as(u32, r) << 16 |
                    @as(u32, g) << 8 |
                    @as(u32, b);

                buf.set_pixel(i, j, xrgb);
            }
        }
    }
};
