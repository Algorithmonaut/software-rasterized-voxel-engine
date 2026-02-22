const cfg = @import("config.zig");
const mat = @import("matrix.zig");

const vec3f = cfg.vec3f;
const float = cfg.float;

pub var projection_matrix: mat.Mat4f = undefined;
pub var from = vec3f{ 0, 0, -6 };
pub var to = vec3f{ 0, 0, -5 };

// P: Camera angles
pub var yaw: float = 0.0;
pub var pitch: float = 0.0;
