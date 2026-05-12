const std = @import("std");
const types = @import("../types.zig");
const helpers = @import("../helpers.zig");
const constants = @import("../constants.zig");
const textures = @import("../assets/textures.zig");

const TEX_SIZE = constants.TEX_SIZE;

const Framebuffer = @import("../Framebuffer.zig").Framebuffer;
const Face = types.Face;
const BlockId = types.BlockId;

pub fn drawTexture(fb: *Framebuffer, face: Face, id: BlockId, x: usize, y: usize) void {
    const texels = textures.getTextureData(id, face, 0);

    for (0..TEX_SIZE) |row| {
        const dst = fb.getScanline(row + y)[x .. x + TEX_SIZE];
        const src = texels[row * TEX_SIZE .. row * TEX_SIZE + TEX_SIZE];
        @memcpy(dst, src);
    }
}

pub fn drawScaledTexture(
    fb: *Framebuffer,
    face: Face,
    id: BlockId,
    comptime scale: usize,
    start_x: usize,
    start_y: usize,
) void {
    std.debug.assert(scale >= 1);

    const texels = textures.getTextureData(id, face, 0);

    // var cursor_y = 0;
    for (0..TEX_SIZE) |y| {
        const start = y * TEX_SIZE;
        const src = texels[start .. start + TEX_SIZE];
        var dst: [TEX_SIZE * scale]u32 = undefined;

        for (0..TEX_SIZE) |x| {
            for (0..scale) |dst_offset_x| dst[x * scale + dst_offset_x] = src[x];
        }

        for (0..scale) |dst_offset_y| {
            const dst_y = y * scale + dst_offset_y;
            const dst_fb = fb.getScanline(dst_y + start_y)[start_x .. start_x + TEX_SIZE * scale];
            @memcpy(dst_fb, &dst);
        }
    }
}

pub fn drawBlockSelector(fb: *Framebuffer, selected_block: BlockId) void {
    const padding = 3;
    const scale = 3;

    const height_offset = 30;

    const border_color: u32 = 0xFFFFFF00;

    // We don't want .air nor .unknown
    const block_count = BlockId.count - 2;

    const tex_slot_dim = (TEX_SIZE * scale) + (padding * 2);
    const width = block_count * tex_slot_dim;
    const height = tex_slot_dim;

    const start_x = (fb.width / 2) - (width / 2);
    const start_y = fb.height - height_offset - height;
    var x = start_x;

    inline for (@typeInfo(BlockId).@"enum".fields) |field| {
        if (field.value == @intFromEnum(BlockId.air) or
            field.value == @intFromEnum(BlockId.unknown)) continue;
        drawScaledTexture(fb, .front, @enumFromInt(field.value), scale, x + padding, start_y + padding);
        x += tex_slot_dim;
    }

    const selected_i: usize = @intCast(@intFromEnum(selected_block) - 1);
    fb.drawRectBorder(
        selected_i * tex_slot_dim + start_x,
        start_y,
        TEX_SIZE * scale + padding * 2,
        TEX_SIZE * scale + padding * 2,
        scale,
        border_color,
    );
}
