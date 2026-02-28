const tex = @import("textures.zig");

// P: Framebuffer dimensions/scale

// pub const width: c_int = 1920;
// pub const height: c_int = 1080;
// pub const scale: c_int = 1;
pub const tile_dimensions: usize = 32;

pub const width: usize = 960;
pub const height: usize = 540;
pub const scale: usize = 2;

// pub const width: c_int = 240;
// pub const height: c_int = 135;
// pub const scale: c_int = 8;

pub const fov: float = 90;
pub const view_distance: float = 200;

// P: Default types

pub const float = f32;
pub const int = i32;
pub const uint = u32;
pub const vec4f = @Vector(4, float);
pub const vec3f = @Vector(3, float);
pub const vec3i = @Vector(3, int);
pub const vec4i = @Vector(4, int);

// P: Debug
pub const show_fps = true;
pub const show_tex_atlas = true;
pub const show_tiles = true;

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
