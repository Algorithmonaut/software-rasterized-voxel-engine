const std = @import("std");

const TEX_SIZE = 16;
const TEXELS_PER_TEX = TEX_SIZE * TEX_SIZE;

const FACE_COUNT = 6;

const Face = enum(u8) {
    pub const count = @typeInfo(BlockId).@"enum".fields.len;
    left,
    right,
    back,
    front,
    bottom,
    top,
};

//// MIP CHAIN ////

fn Mip(comptime size: usize) type {
    return [size * size]u32;
}

const MipChain = struct {
    l0: Mip(16),
    l1: Mip(8),
    l2: Mip(4),
    l3: Mip(2),
    l4: Mip(1),

    pub fn get(self: *const MipChain, level: usize) []const u32 {
        return switch (level) {
            0 => self.l0[0..],
            1 => self.l1[0..],
            2 => self.l2[0..],
            3 => self.l3[0..],
            4 => self.l4[0..],
        };
    }

    fn pixelIndex(size: usize, x: usize, y: usize) usize {
        return x + y * size;
    }

    fn getPixel(tex: []const u32, size: usize, x: usize, y: usize) u32 {
        return tex[pixelIndex(size, x, y)];
    }

    fn generateNextMip(prev_size: usize, prev: []const u32, next: []u32) void {
        const next_size = @max(@as(usize, 1), (prev_size + 1) / 2);

        for (0..next_size) |y| {
            for (0..next_size) |x| {
                const sx = x * 2;
                const sy = y * 2;

                const sx0 = @min(sx + 0, prev_size - 1);
                const sy0 = @min(sy + 0, prev_size - 1);
                const sx1 = @min(sx + 1, prev_size - 1);
                const sy1 = @min(sy + 1, prev_size - 1);

                const p0 = getPixel(prev, prev_size, sx0, sy0);
                const p1 = getPixel(prev, prev_size, sx0, sy1);
                const p2 = getPixel(prev, prev_size, sx1, sy0);
                const p3 = getPixel(prev, prev_size, sx1, sy1);

                // Without (+2): integer division by 4 with truncation
                // With (+2): approximately sum / 4 rounded to nearest
                const avg_a = (((p0 >> 24) & 0xFF) + ((p1 >> 24) & 0xFF) +
                    ((p2 >> 24) & 0xFF) + ((p3 >> 24) & 0xFF) + 2) >> 2;
                const avg_r = (((p0 >> 16) & 0xFF) + ((p1 >> 16) & 0xFF) +
                    ((p2 >> 16) & 0xFF) + ((p3 >> 16) & 0xFF) + 2) >> 2;
                const avg_g = (((p0 >> 8) & 0xFF) + ((p1 >> 8) & 0xFF) +
                    ((p2 >> 8) & 0xFF) + ((p3 >> 8) & 0xFF) + 2) >> 2;
                const avg_b = (((p0 >> 0) & 0xFF) + ((p1 >> 0) & 0xFF) +
                    ((p2 >> 0) & 0xFF) + ((p3 >> 0) & 0xFF) + 2) >> 2;

                next[pixelIndex(next_size, x, y)] =
                    (avg_a << 24) | (avg_r << 16) | (avg_g << 8) | avg_b;
            }
        }
    }

    fn transparent() MipChain {
        return .{
            .l0 = [_]u32{0} ** (16 * 16),
            .l1 = [_]u32{0} ** (8 * 8),
            .l2 = [_]u32{0} ** (4 * 4),
            .l3 = [_]u32{0} ** (2 * 2),
            .l4 = [_]u32{0} ** (1 * 1),
        };
    }

    fn fromEmbedded(comptime path: []const u8) MipChain {
        var chain: MipChain = undefined;

        const bytes = @embedFile(path);
        if (bytes.len != TEX_SIZE * TEX_SIZE * 4)
            @compileError("Invalid texture size for " ++ path);

        for (0..TEX_SIZE * TEX_SIZE) |i| {
            const j = i * 4;
            const b: u32 = bytes[j + 0];
            const g: u32 = bytes[j + 1];
            const r: u32 = bytes[j + 2];
            const a: u32 = bytes[j + 3];

            chain.l0[i] = (a << 24) | (r << 16) | (g << 8) | b;
        }

        generateNextMip(16, &chain.l0, &chain.l1);
        generateNextMip(8, &chain.l1, &chain.l2);
        generateNextMip(4, &chain.l2, &chain.l3);
        generateNextMip(2, &chain.l3, &chain.l4);
    }
};

//// DEFINITIONS ////

const TextureId = enum(usize) {
    air,
    dirt,
    stone,
    grass_block_side,
    grass_block_top,
    sand,
    snow,
    cobblestone,
    stone_bricks,
    bricks,
    oak_plank,
    oak_log_side,
    oak_log_top,
    oak_leaves,
    coal_ore,
    iron_ore,
    deepslate,
    glass,
    ice,

    const count = @typeInfo(TextureId).@"enum".fields.len;

    fn index(self: BlockId) usize {
        return @intFromEnum(self);
    }
};

const BlockId = enum(u8) {
    air = 0,

    dirt = 1,
    stone = 2,
    grass = 3,
    sand = 4,
    snow = 5,
    cobblestone = 6,
    stone_bricks = 7,
    bricks = 8,
    oak_plank = 9,
    oak_log = 10,
    oak_leaves = 11,
    coal_ore = 12,
    iron_ore = 13,
    deepslate = 14,
    glass = 15,
    ice = 16,

    const count = @typeInfo(BlockId).@"enum".fields.len;

    fn index(self: BlockId) usize {
        return @intFromEnum(self);
    }
};

//// BUILD BLOCK DEFS ////

pub const BlockDef = struct {
    faces: [Face.count]TextureId,
    solid: bool = false,
    transparent: bool = false,

    fn all(tex: TextureId) BlockDef {
        return .{ .faces = .{ tex, tex, tex, tex, tex, tex } };
    }

    fn sideBottomTop(side: TextureId, bottom: TextureId, top: TextureId) BlockDef {
        return .{ .faces = .{ side, side, side, side, bottom, top } };
    }

    fn air() BlockDef {
        return .{
            .faces = .{ .air, .air, .air, .air, .air, .air },
            .solid = false,
            .transparent = true,
        };
    }
};

const block_defs: [BlockId.count]BlockDef = buildBlockDefs();

fn buildBlockDefs() [BlockId.count]BlockDef {
    var defs: [BlockId.count]BlockDef = undefined;

    for (&defs) |*def| {
        def.* = BlockDef.air();
    }

    defs[BlockId.air.index()] = BlockDef.air();

    defs[BlockId.dirt.index()] = BlockDef.all(.dirt);
    defs[BlockId.stone.index()] = BlockDef.all(.stone);
    defs[BlockId.grass.index()] = BlockDef.sideBottomTop(
        .grass_block_side,
        .dirt,
        .grass_block_top,
    );

    defs[BlockId.sand.index()] = BlockDef.all(.sand);
    defs[BlockId.snow.index()] = BlockDef.all(.snow);

    defs[BlockId.cobblestone.index()] = BlockDef.all(.cobblestone);
    defs[BlockId.stone_bricks.index()] = BlockDef.all(.stone_bricks);
    defs[BlockId.bricks.index()] = BlockDef.all(.bricks);
    defs[BlockId.oak_plank.index()] = BlockDef.all(.oak_plank);

    defs[BlockId.oak_log.index()] = BlockDef.sideBottomTop(
        .oak_log_side,
        .oak_log_top,
        .oak_log_top,
    );

    defs[BlockId.oak_leaves.index()] = .{
        .faces = BlockDef.all(.oak_leaves).faces,
        .transparent = true,
    };

    defs[BlockId.coal_ore.index()] = BlockDef.all(.coal_ore);
    defs[BlockId.iron_ore.index()] = BlockDef.all(.iron_ore);

    defs[BlockId.deepslate.index()] = BlockDef.all(.deepslate);

    defs[BlockId.glass.index()] = .{
        .faces = BlockDef.all(.glass).faces,
        .transparent = true,
    };

    defs[BlockId.ice.index()] = .{
        .faces = BlockDef.all(.ice).faces,
        .transparent = true,
    };

    return defs;
}

//

const SourceTextures = [TextureId.count]MipChain;

fn buildEmbeddedSource() SourceTextures {
    var textures: SourceTextures = undefined;

    inline for (@typeInfo(TextureId).@"enum".fields) |field| {
        const tex_id: TextureId = @enumFromInt(field.value);
        const i = tex_id.index();

        if (tex_id == .air) textures[i] = MipChain.transparent() else {
            // Make this more obvious
            const path = "assets/textures-argb/" ++ field.name ++ ".argb";
            textures[i] = MipChain.fromEmbedded(path);
        }
    }
}
const embedded_source: SourceTextures = buildEmbeddedSource();

pub fn getTextureData(id: BlockId, face: Face, mip_level: usize) []const u32 {
    const tex_id = block_defs[id.index()].faces[@intFromEnum(face)];
    return embedded_source[tex_id.index()].get(mip_level);
}
