const cfg = @import("config.zig");
const tex = @import("textures.zig");
const mat = @import("matrix.zig");

const vec3f = cfg.vec3f;
const float = cfg.float;
const Mat4f = mat.Mat4f;

pub var projection_matrix: mat.Mat4f = undefined;
pub var from = vec3f{ 0, 0, -6 };
pub var to = vec3f{ 0, 0, -5 };

// P: Texture atlas
pub var atlas: tex.Atlas = undefined;

// P: Camera angles
pub var yaw: float = 0.0;
pub var pitch: float = 0.0;

pub var world_to_camera = Mat4f;
