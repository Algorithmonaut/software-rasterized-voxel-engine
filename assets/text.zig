const std = @import("std");

const Framebuffer = @import("../Framebuffer.zig").Framebuffer;

const GLYPH_FIRST = 32;
const GLYPH_LAST = 126;
const GLYPH_COUNT = (GLYPH_LAST - GLYPH_FIRST) + 1;
const MAX_GLYPH_HEIGHT = 32;
const GlyphRow = u32;

// Maximum of 4 numbers in the fields that I need to read
fn extractNumbers(string: []const u8) [4]isize {
    var it = std.mem.tokenizeScalar(u8, string, ' ');
    var result = [_]isize{0} ** 4;

    var count: usize = 0;
    while (it.next()) |token| {
        if (count == result.len) break;
        result[count] = std.fmt.parseInt(isize, token, 10) catch continue;
        count += 1;
    }

    return result;
}

const SourceText = struct {
    glyph_width: usize,
    glyph_height: usize,

    glyphs: [GLYPH_COUNT][MAX_GLYPH_HEIGHT]GlyphRow,

    fn create() !SourceText {
        // TODO: Make the file name more obvious
        const data = @embedFile("font.bdf");
        var it = std.mem.splitScalar(u8, data, '\n');

        var text = std.mem.zeroes(SourceText);

        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "FONTBOUNDINGBOX")) {
                const numbers = extractNumbers(line);
                text.glyph_width = @intCast(numbers[0]);
                text.glyph_height = @intCast(numbers[1]);
                break;
            }
        }

        var inside_bitmap = false;
        var bitmap_idx: usize = 0;
        var current_glyph_idx: ?usize = null;

        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "ENCODING")) {
                const encoding = extractNumbers(line)[0];

                if (encoding >= GLYPH_FIRST and encoding <= GLYPH_LAST) {
                    current_glyph_idx = @intCast(encoding - GLYPH_FIRST);
                } else {
                    current_glyph_idx = null;
                }

                continue;
            }

            if (std.mem.eql(u8, line, "BITMAP")) {
                inside_bitmap = true;
                bitmap_idx = 0;
                continue;
            }

            if (std.mem.eql(u8, line, "ENDCHAR")) {
                inside_bitmap = false;
                bitmap_idx = 0;
                continue;
            }

            if (inside_bitmap) {
                const glyph_idx = current_glyph_idx orelse continue;

                if (bitmap_idx >= text.glyph_height or bitmap_idx >= MAX_GLYPH_HEIGHT) {
                    return error.TooManyBitmapRows;
                }

                const raw = try std.fmt.parseInt(GlyphRow, line, 16);

                const row_bytes = (text.glyph_width + 7) / 8;
                const row_bits = row_bytes * 8;
                const shift_amount = row_bits - text.glyph_width;

                text.glyphs[glyph_idx][bitmap_idx] =
                    raw >> @intCast(shift_amount);

                bitmap_idx += 1;
            }
        }

        return text;
    }
};

pub const embedded_source: SourceText = blk: {
    @setEvalBranchQuota(1_000_000);

    break :blk SourceText.create() catch |err| {
        @compileError(@errorName(err));
    };
};

pub inline fn printText(
    start_x: usize,
    start_y: usize,
    text: []const u8,
    color: u32,
    fb: *Framebuffer,
) void {
    var x_offset: usize = 0;

    for (text) |letter| {
        if (letter < GLYPH_FIRST or letter > GLYPH_LAST) {
            x_offset += embedded_source.glyph_width;
            continue;
        }

        const glyph = &embedded_source.glyphs[letter - GLYPH_FIRST];

        for (0..embedded_source.glyph_height) |y| {
            const row = glyph[y];

            for (0..embedded_source.glyph_width) |x| {
                const shift = embedded_source.glyph_width - 1 - x;
                const bit = (row >> @intCast(shift)) & 1;

                if (bit == 0) {
                    fb.setPixel(start_x + x_offset + x, start_y + y, 0xFF000000);
                    continue;
                }

                fb.setPixel(start_x + x_offset + x, start_y + y, color);
            }
        }

        x_offset += embedded_source.glyph_width;
    }
}
