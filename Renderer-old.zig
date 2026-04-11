const std = @import("std");

const RasterTriangle = @import("triangle.zig").RasterTriangle;
const World = @import("world/World.zig").World;
const Camera = @import("game/Camera.zig").Camera;
const Chunk = @import("world/Chunk.zig").Chunk;
const Atlas = @import("Atlas.zig").Atlas;
const TerrainGenerator = @import("world/TerrainGenerator.zig").TerrainGenerator;

const Block = @import("world/Block.zig");
const WorldQuad = Block.WorldQuad;
const WorldVertex = Block.WorldVertex;
const WorldTriangle = Block.WorldTriangle;
const Vertex = Block.Vertex;

const Mat4f = @import("math/matrix.zig").Mat4f;

const types = @import("math/types.zig");
const Vec4f = types.Vec4f;
const Vec3f = types.Vec3f;
const Float = types.Float;
const Int = types.Int;
const WorldCoord = types.WorldCoord;
const ChunkCoord = types.ChunkCoord;

const Vec2fx = types.Vec2fx;

pub const Renderer = struct {
    triangles: std.ArrayList(RasterTriangle),
    chunk_entries: std.ArrayList(ChunkRenderEntry),

    fb_width: usize,
    fb_height: usize,
    tile_dimensions: usize,

    planes: [5]Vec4f = undefined, // left right bottom top near

    pub fn init(
        allocator: std.mem.Allocator,
        conf: FramebufferConfig,
        view_distance: Float,
    ) !Renderer {
        // TODO: Find a better way to do this
        const half_view_dist: usize = @intFromFloat(view_distance / 2);
        const estimate = half_view_dist * half_view_dist * half_view_dist;

        return .{
            .triangles = try std.ArrayList(RasterTriangle).initCapacity(
                allocator,
                10_000,
            ),
            .chunk_entries = try std.ArrayList(ChunkRenderEntry).initCapacity(
                allocator,
                estimate,
            ),

            .fb_width = conf.width,
            .fb_height = conf.height,
            .tile_dimensions = conf.tile_dimensions,
        };
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        self.triangles.clearAndFree(allocator);
        self.chunk_entries.clearAndFree(allocator);
    }

    pub fn beginFrame(self: *Renderer) void {
        self.triangles.clearRetainingCapacity();
    }

    // QUAD RENDERING //////////////////////////////////////////////////////////

    fn emitClippedQuad(
        self: *Renderer,
        allocator: std.mem.Allocator,
        quad: WorldQuad,
    ) !void {
        const c0 = clipCode(quad.v0.pos);
        const c1 = clipCode(quad.v1.pos);
        const c2 = clipCode(quad.v2.pos);
        const c3 = clipCode(quad.v3.pos);

        const or_code = c0 | c1 | c2 | c3;
        const and_code = c0 & c1 & c2 & c3;

        if (and_code != 0) return; // quad trivially outside
        if (or_code == 0) { // quad trivially inside
            try emitQuad(self, allocator, quad);
            return;
        }
        // if (or_code != 0) return; // TEMP: drop partially clipped tris

        var clipped_polygon: ClippedPolygon = undefined;
        clipped_polygon.verts[0] = quad.v0;
        clipped_polygon.verts[1] = quad.v1;
        clipped_polygon.verts[2] = quad.v2;
        clipped_polygon.verts[3] = quad.v3;
        clipped_polygon.len = 4;
    }

    inline fn genRasterTriangleFromWorldQuad(
        self: *Renderer,
        allocator: std.mem.Allocator,
        quad: WorldQuad,
        combined_clip_transform: Mat4f,
    ) !void {
        var projected_quad = quad;
        projected_quad.v0.pos =
            combined_clip_transform.mul_vec(projected_quad.v0.pos);
        projected_quad.v1.pos =
            combined_clip_transform.mul_vec(projected_quad.v1.pos);
        projected_quad.v2.pos =
            combined_clip_transform.mul_vec(projected_quad.v2.pos);
        projected_quad.v3.pos =
            combined_clip_transform.mul_vec(projected_quad.v3.pos);

        try emitClippedQuad(self, allocator, projected_quad);
    }

    // CHUNK RENDERING /////////////////////////////////////////////////////////

};
