const std = @import("std");

// Assuming 16x16 textures
const rgb_tex_bytes = (16 * 16) * 3;
const xrgb_tex_bytes = (16 * 16) * 4;

const tex_dimensions: usize = 16;

const blocks_count = 3;
const mips_level = 5;

const atlas_bytes = blocks_count * 6 * xrgb_tex_bytes;
const mip_atlas_bytes = atlas_bytes * mips_level;

fn getXrgbFromFile(filename: []const u8) ![xrgb_tex_bytes]u8 {
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

fn writeAtlasToFile(atlas: [mip_atlas_bytes]u8, filename: []const u8) !void {
    const cwd = std.fs.cwd();

    var file = try cwd.createFile(filename, .{ .truncate = true });
    defer file.close();

    var write_buf: [atlas.len]u8 = undefined;
    var file_writer = file.writer(&write_buf);
    const writer = &file_writer.interface;

    try writer.writeAll(atlas[0..]);
    try writer.flush();
}

fn blitTile(
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

        const src = texture.*[src_start..src_end];

        const dst_x = col * texture_stride;
        const dst_y = (row * texture_dimensions + y) * atlas_stride;
        const dst_start = dst_y + dst_x;
        const dst_end = dst_start + texture_stride;
        const dst = atlas[dst_start..dst_end];

        @memcpy(dst, src);
    }
}

fn getPixel(tex: []const u8, x: usize, y: usize) u32 {
    const i = (y * tex_dimensions + x) * 4;
    const b = @as(u32, tex[i + 0]);
    const g = @as(u32, tex[i + 1]);
    const r = @as(u32, tex[i + 2]);
    const a = @as(u32, tex[i + 3]);
    return (a << 24) | (r << 16) | (g << 8) | b;
}

fn setPixel(tex: []u8, x: usize, y: usize, pixel: u32) void {
    const i = (y * tex_dimensions + x) * 4;
    tex[i + 0] = @intCast(pixel & 0xFF);
    tex[i + 1] = @intCast((pixel >> 8) & 0xFF);
    tex[i + 2] = @intCast((pixel >> 16) & 0xFF);
    tex[i + 3] = @intCast((pixel >> 24) & 0xFF);
}

// Looking only the first pixel is enough
fn getLogicalPixel(tex: []const u8, level: usize, lx: usize, ly: usize) u32 {
    const block_size = @as(usize, 1) << @as(u6, @intCast(level)); // 1, 2, 4, 8, 16
    return getPixel(tex, lx * block_size, ly * block_size);
}

fn setLogicalPixelReplicated(
    tex: []u8,
    level: usize,
    lx: usize,
    ly: usize,
    pixel: u32,
) void {
    const block_size = @as(usize, 1) << @as(u6, @intCast(level)); // 1, 2, 4, 8, 16

    const start_x = lx * block_size;
    const start_y = ly * block_size;

    for (0..block_size) |dy|
        for (0..block_size) |dx|
            setPixel(tex, start_x + dx, start_y + dy, pixel);
}

fn average4(p0: u32, p1: u32, p2: u32, p3: u32) u32 {
    // Without (+2): integer division by 4 with truncation
    // With (+2): approximately sum / 4 rounded to nearest
    const a = (((p0 >> 24) & 0xFF) + ((p1 >> 24) & 0xFF) +
        ((p2 >> 24) & 0xFF) + ((p3 >> 24) & 0xFF) + 2) >> 2;
    const r = (((p0 >> 16) & 0xFF) + ((p1 >> 16) & 0xFF) +
        ((p2 >> 16) & 0xFF) + ((p3 >> 16) & 0xFF) + 2) >> 2;
    const g = (((p0 >> 8) & 0xFF) + ((p1 >> 8) & 0xFF) +
        ((p2 >> 8) & 0xFF) + ((p3 >> 8) & 0xFF) + 2) >> 2;
    const b = (((p0 >> 0) & 0xFF) + ((p1 >> 0) & 0xFF) +
        ((p2 >> 0) & 0xFF) + ((p3 >> 0) & 0xFF) + 2) >> 2;

    return (a << 24) | (r << 16) | (g << 8) | b;
}

fn generateNextMip(
    prev: []const u8,
    next: []u8,
    next_level: usize,
) void {
    @memset(next, 0);

    const next_logical_size = tex_dimensions >> @as(u6, @intCast(next_level));

    for (0..next_logical_size) |y| {
        for (0..next_logical_size) |x| {
            const p0 = getLogicalPixel(prev, next_level - 1, x * 2 + 0, y * 2 + 0);
            const p1 = getLogicalPixel(prev, next_level - 1, x * 2 + 1, y * 2 + 0);
            const p2 = getLogicalPixel(prev, next_level - 1, x * 2 + 0, y * 2 + 1);
            const p3 = getLogicalPixel(prev, next_level - 1, x * 2 + 1, y * 2 + 1);

            const avg = average4(p0, p1, p2, p3);
            setLogicalPixelReplicated(next, next_level, x, y, avg);
        }
    }
}

fn generateBlockTexture(filename: []const u8) ![mips_level][xrgb_tex_bytes]u8 {
    var result: [mips_level][xrgb_tex_bytes]u8 = undefined;

    result[0] = try getXrgbFromFile(filename);

    for (1..mips_level) |level|
        generateNextMip(result[level - 1][0..], result[level][0..], level);

    return result;
}

pub fn main() !void {
    const dirt = try generateBlockTexture("dirt.rgb");
    const stone = try generateBlockTexture("stone.rgb");
    const grass_side = try generateBlockTexture("grass-side.rgb");
    const grass_top = try generateBlockTexture("grass-top.rgb");

    // back front left right bottom top
    const BlockFaces = [6]*const [mips_level][xrgb_tex_bytes]u8;
    const dirt_block: BlockFaces = .{ &dirt, &dirt, &dirt, &dirt, &dirt, &dirt };
    const stone_block: BlockFaces = .{ &stone, &stone, &stone, &stone, &stone, &stone };
    const grass_block: BlockFaces = .{ &grass_side, &grass_side, &grass_side, &grass_side, &dirt, &grass_top };

    const blocks: [blocks_count]*const BlockFaces = .{ &dirt_block, &stone_block, &grass_block };

    var atlas: [mip_atlas_bytes]u8 = undefined;

    for (blocks, 0..) |block, block_row|
        for (block.*, 0..) |face, face_col|
            for (face.*, 0..) |mip, mip_row|
                blitTile(atlas[0..], &mip, face_col, mip_row * blocks_count + block_row);

    try writeAtlasToFile(atlas, "atlas.argb");

    try writeAtlasToFile(atlas, "atlas.argb");
}
