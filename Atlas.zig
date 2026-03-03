const std = @import("std");
const cfg = @import("config.zig");
const Framebuffer = @import("Framebuffer.zig").Framebuffer;
const AtlasConfig = @import("engine/EngineConfig.zig").EngineConfig.AtlasConfig;

pub const BlockTypes = enum(usize) {
    dirt = 0,
    stone = 1,
    grass = 2,
};

pub const Atlas = struct {
    atlas: []u32,

    width: usize,
    height: usize,
    tex_w: usize,
    tex_h: usize,
    size: usize,

    pub fn init(allocator: std.mem.Allocator, conf: AtlasConfig) !Atlas {
        const atlas_size = conf.width * conf.height;
        const atlas_size_rgb = conf.width * conf.height * 4;

        const cwd = std.fs.cwd();
        var dir = try cwd.openDir("tex/", .{});
        defer dir.close();
        var file = try dir.openFile("atlas.argb", .{ .mode = .read_only });
        defer file.close();

        const read_buf = try allocator.alloc(u8, atlas_size_rgb);
        defer allocator.free(read_buf);

        var file_reader = file.reader(read_buf);
        const reader = &file_reader.interface;

        const atlas = try allocator.alloc(u32, atlas_size);
        // defer allocator.free(atlas);

        try reader.readSliceAll(std.mem.sliceAsBytes(atlas));

        // const atlas_u32: []u32 =
        //     @as([*]u32, @ptrCast(@alignCast(atlas.ptr)))[0 .. atlas.len / 4];

        // Ensure there is not trailing data
        var extra: [1]u8 = undefined;
        const m = try reader.readSliceShort(&extra);
        if (m != 0) return error.UnexpectedTrailingData;

        return .{
            .atlas = atlas,
            .width = conf.width,
            .height = conf.height,
            .tex_w = conf.tex_w,
            .tex_h = conf.tex_h,
            .size = atlas_size,
        };
    }

    pub fn deinit(self: Atlas, allocator: std.mem.Allocator) void {
        allocator.free(self.atlas);
    }

    pub fn debug_show_atlas(self: *const Atlas, buf: *Framebuffer) void {
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            const base_addr_src = y * self.width;

            const src = self.atlas[base_addr_src .. base_addr_src + self.width];
            const dst = buf.get_scanline(y)[0..self.width];
            @memcpy(dst, src);
        }
    }
};
