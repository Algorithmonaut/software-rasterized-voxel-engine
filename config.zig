const tex = @import("textures.zig");

// P: Framebuffer dimensions/scale

pub const tile_dimensions: usize = 64;
pub const width: usize = 960;
pub const height: usize = 540;
pub const scale: usize = 2;

pub const fov: Float = 90;
pub const view_distance: Float = 200;

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
pub const show_tex_atlas = true;
pub const show_tiles = false;

// P: Input
pub const mouse_sensivity: f32 = 0.0025;

// P: Texture atlas
pub const atlas_w = 96;
pub const atlas_h = 48;
pub const tex_w = 16;
pub const tex_h = 16;
pub const atlas_channels = 1;
pub const atlas_size = atlas_w * atlas_h * atlas_channels;

pub const atlas_channels_rgb = 3;
pub const atlas_size_rgb = atlas_w * atlas_h * atlas_channels_rgb;
