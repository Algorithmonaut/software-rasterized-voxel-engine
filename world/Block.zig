const std = @import("std");
const t = @import("../math/types.zig");

/// The vertex position should be in chunk space
pub const Vertex = struct {
    pos: [3]usize,
    uv: [2]usize,
};

pub const Quad = struct {
    v0: Vertex,
    v1: Vertex,
    v2: Vertex,
    v3: Vertex,
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
