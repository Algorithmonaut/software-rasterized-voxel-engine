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

pub const BlockId = enum(u8) {
    air = 254,
    unknown = 255,
    dirt = 0,
    stone = 1,
    grass = 2,
};

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
    solid_x: Bitfields, // [y][z], bits are x
    solid_y: Bitfields, // [x][z], bits are y
    solid_z: Bitfields, // [x][y], bits are z
};

pub const FrameContext = struct {
    dt: f32,
    framebuffer: Framebuffer.Framebuffer,
};

pub const Face = enum(u8) { left, right, back, front, bottom, top };
