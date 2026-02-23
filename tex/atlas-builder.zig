const std = @import("std");

const bytes_count: usize = 16 * 16 * 3;
const blocks_count: usize = 3;
const out_size: usize = bytes_count * 6 * blocks_count;

const tile_w: usize = 16;
const tile_h: usize = 16;
const channels: usize = 3;

const faces_per_block: usize = 6;
const atlas_w: usize = tile_w * faces_per_block; // 96
const atlas_h: usize = tile_h * blocks_count; // 48
const atlas_size: usize = atlas_w * atlas_h * channels;

// P: Read from file, write to file

fn read_file(filename: []const u8) ![bytes_count]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    const cwd = std.Io.Dir.cwd();

    var file = try cwd.openFile(io, filename, .{ .mode = .read_only });
    defer file.close(io);

    var read_buf: [bytes_count]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const reader = &file_reader.interface;

    var rgb: [bytes_count]u8 = undefined;
    try reader.readSliceAll(&rgb);

    // Ensure there is no trailing data (file is exactly 768 bytes)
    var extra: [1]u8 = undefined;
    const m = try reader.readSliceShort(&extra);
    if (m != 0) return error.UnexpectedTrailingData;

    return rgb;
}

fn write_to_file(a: [out_size]u8, filename: []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    const cwd = std.Io.Dir.cwd();

    // Create/overwrite output file
    var file = try cwd.createFile(io, filename, .{
        .truncate = true,
        // .read = false, // usually default for write-only create, depends on current flags shape
    });
    defer file.close(io);

    // Buffered writer (caller-provided buffer)
    var write_buf: [a.len]u8 = undefined;
    var file_writer = file.writer(io, &write_buf);
    const writer = &file_writer.interface;

    // Write exactly all bytes
    try writer.writeAll(&a);

    // Flush buffered data to file
    try writer.flush();

    const preview_command =
        \\ PREVIEW ATLAS:
        \\magick -size {}x{} -depth 8 rgb:atlas.rgb \
        \\-filter point -resize 512x512 png:- | feh -
    ;

    std.debug.print(preview_command, .{ atlas_w, atlas_h });
}

// P: Main

fn blit_tile(
    atlas: []u8,
    tile: *const [bytes_count]u8,
    col: usize,
    row: usize,
) void {
    const tile_stride = tile_w * channels; // 48 bytes per tile row
    const atlas_stride = atlas_w * channels; // 288 bytes per atlas row

    for (0..tile_h) |y| {
        const src_start = y * tile_stride;
        const src_end = src_start + tile_stride;
        const src = tile[src_start..src_end];

        const dst_x = col * tile_stride;
        const dst_y = (row * tile_h + y) * atlas_stride;
        const dst_start = dst_y + dst_x;
        const dst_end = dst_start + tile_stride;

        @memcpy(atlas[dst_start..dst_end], src);
    }
}

pub fn main() !void {
    const dirt = try read_file("dirt.rgb");
    const stone = try read_file("stone.rgb");
    const grass_side = try read_file("grass-side.rgb");
    const grass_top = try read_file("grass-top.rgb");

    // back front left right bottom top
    const BlockFaces = [6]*const [bytes_count]u8;
    const dirt_block: BlockFaces = .{ &dirt, &dirt, &dirt, &dirt, &dirt, &dirt };
    const stone_block: BlockFaces = .{ &stone, &stone, &stone, &stone, &stone, &stone };
    const grass_block: BlockFaces = .{ &grass_side, &grass_side, &grass_side, &grass_side, &dirt, &grass_top };

    const blocks: [blocks_count]*const BlockFaces = .{ &dirt_block, &stone_block, &grass_block };

    var out_buf: [atlas_size]u8 = undefined;

    for (blocks, 0..) |block, block_row| {
        for (block.*, 0..) |face, face_col| {
            blit_tile(out_buf[0..], face, face_col, block_row);
        }
    }

    try write_to_file(out_buf, "atlas.rgb");
}
