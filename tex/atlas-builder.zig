const std = @import("std");

// Assuming 16x16 textures
const rgb_tex_bytes = (16 * 16) * 3;
const xrgb_tex_bytes = (16 * 16) * 4;

const blocks_count = 3;
const atlas_bytes = blocks_count * 6 * xrgb_tex_bytes;

fn get_xrgb_from_file(filename: []const u8) ![xrgb_tex_bytes]u8 {
    var file = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });
    defer file.close();

    // OK if buffer is smaller than the full length of what needs to be read
    var io_buf: [1024]u8 = undefined;
    var file_reader = file.reader(&io_buf);
    const reader: *std.Io.Reader = &file_reader.interface;

    var buf: [rgb_tex_bytes]u8 = undefined;
    try reader.readSliceAll(buf[0..]);

    var tex: [xrgb_tex_bytes]u8 = undefined;

    var i: usize = 0; // index into buf (input) (RGB)
    var o: usize = 0; // index into tex (output) (XRGB)

    // Little-endian CPU is assumed, otherwise invert the order
    while (i < buf.len) : (i += 3) {
        tex[o + 3] = 0xFF;
        tex[o + 2] = buf[i + 0];
        tex[o + 1] = buf[i + 1];
        tex[o + 0] = buf[i + 2];
        o += 4;
    }

    return tex;
}

fn write_atlas_to_file(atlas: [atlas_bytes]u8, filename: []const u8) !void {
    const cwd = std.fs.cwd();

    var file = try cwd.createFile(filename, .{ .truncate = true });
    defer file.close();

    var write_buf: [atlas.len]u8 = undefined;
    var file_writer = file.writer(&write_buf);
    const writer = &file_writer.interface;

    try writer.writeAll(atlas[0..]);
    try writer.flush();
}

fn blit_tile(
    atlas: []u8,
    texture: *const [xrgb_tex_bytes]u8,
    col: usize,
    row: usize,
) void {
    const texture_dimensions = 16;
    const texture_stride = texture_dimensions * 4;
    const atlas_stride = 6 * texture_stride;

    for (0..texture_dimensions) |y| {
        const src_start = y * texture_stride;
        const src_end = src_start + texture_stride;

        // FIX: using .* and not using it does not yields the same type,
        // check for this in the rest of the code
        const src = texture.*[src_start..src_end];

        const dst_x = col * texture_stride;
        const dst_y = (row * texture_dimensions + y) * atlas_stride;
        const dst_start = dst_y + dst_x;
        const dst_end = dst_start + texture_stride;
        const dst = atlas[dst_start..dst_end];

        @memcpy(dst, src);
    }
}

pub fn main() !void {
    const dirt = try get_xrgb_from_file("dirt.rgb");
    const stone = try get_xrgb_from_file("stone.rgb");
    const grass_side = try get_xrgb_from_file("grass-side.rgb");
    const grass_top = try get_xrgb_from_file("grass-top.rgb");

    // back front left right bottom top
    const BlockFaces = [6]*const [xrgb_tex_bytes]u8;
    const dirt_block: BlockFaces = .{ &dirt, &dirt, &dirt, &dirt, &dirt, &dirt };
    const stone_block: BlockFaces = .{ &stone, &stone, &stone, &stone, &stone, &stone };
    const grass_block: BlockFaces = .{ &grass_side, &grass_side, &grass_side, &grass_side, &dirt, &grass_top };

    const blocks: [blocks_count]*const BlockFaces = .{ &dirt_block, &stone_block, &grass_block };

    var atlas: [atlas_bytes]u8 = undefined;

    for (blocks, 0..) |block, block_row| {
        for (block.*, 0..) |face, face_col| {
            blit_tile(atlas[0..], face, face_col, block_row);
        }
    }

    try write_atlas_to_file(atlas, "atlas.argb");
}
