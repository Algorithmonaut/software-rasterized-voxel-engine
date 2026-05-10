const constants = @import("constants.zig");

const Framebuffer = @import("Framebuffer.zig");

//

pub const F3 = @Vector(3, f32);
pub const F4 = @Vector(4, f32);
pub const I3 = @Vector(3, i32);
pub const I4 = @Vector(4, i32);
pub const FX2 = @Vector(2, i32);
pub const UV = @Vector(2, f32);

pub const WorldCoord = @Vector(3, f32);
pub const WorldVoxelCoord = @Vector(3, i32);

pub const ChunkCoord = @Vector(3, i32);
pub const ChunkSliceCoord = @Vector(2, i32); // x, z

pub const WorldVertex = struct { pos: F4, uv: UV };

pub const Block = struct {
    id: BlockId,
    /// 4 bits for block light, 4 bits for sky light  (0..15)
    light_level: u8,
};

pub const ChunkState = enum(u8) {
    absent,
    generating,
    generated,
    meshing,
    ready,
};

pub const Bitfields = [constants.CHUNK_SIZE][constants.CHUNK_SIZE]u32;

pub const BitfieldViews = struct {
    renderable_x: Bitfields, // [y][z], bits are x
    renderable_y: Bitfields, // [x][z], bits are y
    renderable_z: Bitfields, // [x][y], bits are z

    // Used for proper meshing of cutout (pseudo transparent blocks)
    occluder_x: Bitfields,
    occluder_y: Bitfields,
    occluder_z: Bitfields,
};

pub const FrameContext = struct {
    dt: f32,
    framebuffer: Framebuffer.Framebuffer,
};

pub const Face = enum(u8) {
    left,
    right,
    back,
    front,
    bottom,
    top,

    pub const count = @typeInfo(Face).@"enum".fields.len;
};

pub const BlockId = enum(u8) {
    air = 0,

    dirt = 1,
    stone = 2,
    grass = 3,
    sand = 4,
    snow = 5,
    cobblestone = 6,
    stone_bricks = 7,
    bricks = 8,
    oak_planks = 9,
    oak_log = 10,
    oak_leaves = 11,
    coal_ore = 12,
    iron_ore = 13,
    deepslate = 14,
    glass = 15,
    ice = 16,

    unknown = 255,

    pub const count = @typeInfo(BlockId).@"enum".fields.len;

    pub fn index(self: BlockId) usize {
        return @intFromEnum(self);
    }
};
