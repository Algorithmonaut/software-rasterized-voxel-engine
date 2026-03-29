pub const Float = f32;
pub const Int = i32;
pub const Uint = u32;
pub const Vec3f = @Vector(3, Float);
pub const Vec4f = @Vector(4, Float);
pub const Vec3i = @Vector(3, Int);
pub const Vec4i = @Vector(4, Int);

pub const ChunkCoord = @Vector(3, i32);
pub const WorldCoord = @Vector(3, f32);

/// Fixed point screen coordinates
pub const Vec2fx = @Vector(2, i32);
pub const SUBPIXEL_BITS = 4;
pub const SUBPIXEL_SCALE = 1 << SUBPIXEL_BITS; // 16
pub const HALF_SUBPIXEL = 1 << (SUBPIXEL_BITS - 1); // 8
