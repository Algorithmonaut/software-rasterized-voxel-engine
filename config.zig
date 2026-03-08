// P: Framebuffer dimensions/scale

pub const tile_dimensions: usize = 8;
pub const width: usize = 1920;
pub const height: usize = 1080;
pub const scale: usize = 1;

// P: Default types
pub const Float = f32;
pub const Int = i32;
pub const Uint = u32;
pub const Vec4f = @Vector(4, Float);
pub const Vec3f = @Vector(3, Float);
pub const Vec3i = @Vector(3, Int);
pub const Vec4i = @Vector(4, Int);

// P: Debug
pub const show_fps = true;
pub const show_tex_atlas = false;
pub const show_tiles = false;
