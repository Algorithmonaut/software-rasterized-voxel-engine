// P: Framebuffer dimensions/scale

pub const tile_dimensions: usize = 16;
pub const width: usize = 960;
pub const height: usize = 540;
pub const scale: usize = 2;

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

// P: Input
pub const mouse_sensivity: f32 = 0.0025;
