// P: Framebuffer dimensions/scale

// pub const width: c_int = 1920;
// pub const height: c_int = 1080;
// pub const scale: c_int = 1;

pub const width: usize = 960;
pub const height: usize = 540;
pub const scale: usize = 2;

// pub const width: c_int = 240;
// pub const height: c_int = 135;
// pub const scale: c_int = 4;

// P: Default types

pub const float = f32;
pub const int = i32;
pub const vec4f = @Vector(4, float);
pub const vec3f = @Vector(3, float);

// P: Debug

pub const show_fps = true;
