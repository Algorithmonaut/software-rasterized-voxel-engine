const std = @import("std");

const Renderer = @import("../Renderer.zig").Renderer;
const ProjectedVertex = Renderer.ProjectedVertex;

pub const Rasterizer = struct {
    render_wireframe: bool,
    render_linear_depth: bool,

    // TODO: Maybe change to u32
    tile_counts: []usize,
    tile_offsets: []usize,
    /// Per tile write cursor, same as tile_offsets before 2nd pass
    write_pos: []usize,
    /// For all tiles, holds the indices of the triangles that overlap
    tile_primitive_indices: []usize,

    pub fn init(allocator: std.mem.Allocator, tile_count: usize) !Rasterizer {
        return .{
            .tile_counts = try allocator.alloc(usize, tile_count),
            .tile_offsets = try allocator.alloc(usize, tile_count + 1),
            .write_pos = try allocator.alloc(usize, tile_count + 1),
            .tile_primitive_indices = try allocator.alloc(usize, 70_000),
        };
    }

    pub fn deinit(self: *Rasterizer, allocator: std.mem.Allocator) void {
        allocator.free(self.tile_counts);
        allocator.free(self.tile_offsets);
        allocator.free(self.write_pos);
        allocator.free(self.tile_primitive_indices);
    }

    inline fn tileRangeForPrimitive(
        vertices: []ProjectedVertex,
        tile_dimensions: usize,
        fb_width: usize,
        fb_height: usize,
    ) struct { min_tx: usize, max_tx: usize, min_ty: usize, max_ty: usize } {}
};
