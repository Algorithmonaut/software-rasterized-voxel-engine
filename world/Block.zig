const std = @import("std");

const t = @import("../math/types.zig");
const Float = t.Float; // NOTE: Maybe change to f64
const Vec3f = t.Vec3f;

/// The vertex position should be in chunk space
pub const Vertex = struct {
    pos: @Vector(3, usize),
    uv: [2]usize,
};

pub const WorldVertex = struct {
    pos: Vec3f,
    uv: [2]usize,
};

pub const Quad = struct {
    v0: Vertex,
    v1: Vertex,
    v2: Vertex,
    v3: Vertex,

    u: usize,
    v: usize,
    atlas_tile_size: usize,
};

pub const WorldQuad = struct {
    v0: WorldVertex,
    v1: WorldVertex,
    v2: WorldVertex,
    v3: WorldVertex,

    // Used to warp the texture of greedy merged quads
    tex_u: usize,
    tex_v: usize,
    tex_tile_size: usize,
};

pub const WorldTriangle = struct {
    v0: WorldVertex,
    v1: WorldVertex,
    v2: WorldVertex,

    // Used to warp the texture of greedy merged quads
    tex_u: usize,
    tex_v: usize,
    tex_tile_size: usize,
};

pub const BlockId = enum(u8) {
    air = 255,
    dirt = 0,
    stone = 1,
    grass = 2,
};

pub const Face = enum(u3) {
    back,
    front,
    left,
    right,
    bottom,
    top,
};
