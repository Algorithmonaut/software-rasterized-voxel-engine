const cfg = @import("config.zig");
const tex = @import("textures.zig");
const mat = @import("matrix.zig");

const Vec3f = cfg.Vec3f;
const Float = cfg.Float;
const Mat4f = mat.Mat4f;

pub var projection_matrix: mat.Mat4f = undefined;

// P: Texture atlas
pub var atlas: tex.Atlas = undefined;

// P: Camera angles
pub var yaw: Float = 0.0;
pub var pitch: Float = 0.0;

pub var world_to_camera = Mat4f;
