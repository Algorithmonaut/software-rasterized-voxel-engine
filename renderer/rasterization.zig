const std = @import("std");

const Renderer = @import("../Renderer.zig").Renderer;
const ProjectedVertex = Renderer.ProjectedVertex;
const MaterialRef = Renderer.MaterialRef;
const PrimitiveRef = Renderer.PrimitiveRef;

const Tile = @import("../tile.zig").Tile;
const Atlas = @import("../Atlas.zig").Atlas;
const TilePool = @import("../tile.zig").TilePool;

const types = @import("../math/types.zig");
const Vec2fx = types.Vec2fx;
const SUBPIXEL_BITS = types.SUBPIXEL_BITS;
const SUBPIXEL_SCALE = types.SUBPIXEL_SCALE;
const HALF_SUBPIXEL = types.HALF_SUBPIXEL;
const I3 = types.Vec3i;

// TODO: Centralize this
const TEX_TILE_SIZE = 16;

// TODO: Centralize this
const UV = @Vector(2, f32);

// Effectively mip = floor(log2(rho))
// TODO: Understand this code
inline fn mipFromRho(rho_in: f32, max_mip: u32) u32 {
    const rho = @max(rho_in, 1.0);
    const bits: u32 = @bitCast(rho);
    const exp: i32 = @as(i32, @intCast((bits >> 23) & 0xff)) - 127;
    const mip: i32 = @max(exp, 0);
    return @min(@as(u32, @intCast(mip)), max_mip);
}

inline fn triangleFullyOutsideTile(
    tri: *const LocalTriangle,
    tile: *const Tile,
) bool {
    const px_step: i32 = 1 << SUBPIXEL_BITS;

    const x0: i32 = (@as(i32, @intCast(tile.pos[0])) << SUBPIXEL_BITS) + HALF_SUBPIXEL;
    const y0: i32 = (@as(i32, @intCast(tile.pos[1])) << SUBPIXEL_BITS) + HALF_SUBPIXEL;

    const x1: i32 = x0 + @as(i32, @intCast(tile.dimensions - 1)) * px_step;
    const y1: i32 = y0 + @as(i32, @intCast(tile.dimensions - 1)) * px_step;

    const edges = [_]Edge{ tri.e0, tri.e1, tri.e2 };
    const biases = [_]i32{
        tri.e0.top_left_bias + tri.e0.cons_bias,
        tri.e1.top_left_bias + tri.e1.cons_bias,
        tri.e2.top_left_bias + tri.e2.cons_bias,
    };

    inline for (0..3) |i| {
        const e = edges[i];

        const mx = if (e.A >= 0) x1 else x0;
        const my = if (e.B >= 0) y1 else y0;

        const max_val = e.eval(mx, my) + biases[i];

        if (max_val < 0) return true;
    }

    return false;
}

//// EDGE //////////////////////////////////////////////////////////////////////

pub const Edge = struct {
    A: i32,
    B: i32,
    C: i32,

    top_left_bias: i32,
    cons_bias: i32, // conservative offset used to mitigate T-junctions cracks

    inline fn eval(self: Edge, x: i32, y: i32) i32 {
        return self.A * x + self.B * y + self.C;
    }
};

inline fn makeEdge(a: @Vector(2, i32), b: @Vector(2, i32)) Edge {
    const x0 = a[0];
    const y0 = a[1];
    const x1 = b[0];
    const y1 = b[1];
    const dy = y1 - y0;
    const dx = x1 - x0;

    const is_top_left: bool = (dy > 0) or (dy == 0 and dx < 0);

    const eA = y1 - y0;
    const eB = x0 - x1;

    const tx: i32 = if (eA >= 0) 1 else 0;
    const ty: i32 = if (eB >= 0) 1 else 0;

    return .{
        .A = eA,
        .B = eB,
        .C = y0 * x1 - x0 * y1,
        .top_left_bias = if (is_top_left) 0 else -1,
        .cons_bias = eA * tx + eB * ty,
    };
}

//// TRIANGLE SETUP ////////////////////////////////////////////////////////////

const LocalTriangle = struct {
    v0: Vec2fx,
    v1: Vec2fx,
    v2: Vec2fx,

    q0: f32,
    q1: f32,
    q2: f32,

    uv0: UV,
    uv1: UV,
    uv2: UV,

    e0: Edge,
    e1: Edge,
    e2: Edge,
    area: i32,
    inv_area: f32,

    tex_u: u16,
    tex_v: u16,
};

inline fn setupLocalTriangle(
    a: ProjectedVertex,
    b: ProjectedVertex,
    c: ProjectedVertex,
    tex_u: u16,
    tex_v: u16,
) LocalTriangle {
    var tri = LocalTriangle{
        .v0 = a.xy,
        .v1 = b.xy,
        .v2 = c.xy,

        .q0 = a.q,
        .q1 = b.q,
        .q2 = c.q,

        .uv0 = a.uv,
        .uv1 = b.uv,
        .uv2 = c.uv,

        .e0 = undefined,
        .e1 = undefined,
        .e2 = undefined,
        .area = 0,
        .inv_area = 0,

        .tex_u = tex_u,
        .tex_v = tex_v,
    };

    tri.e0 = makeEdge(tri.v1, tri.v2);
    tri.e1 = makeEdge(tri.v2, tri.v0);
    tri.e2 = makeEdge(tri.v0, tri.v1);
    tri.area = tri.e0.eval(tri.v0[0], tri.v0[1]);
    tri.inv_area = 1.0 / @as(f32, @floatFromInt(tri.area));

    return tri;
}

//// TRIANGLE RASTERIZATION ////////////////////////////////////////////////////

inline fn rasterLocalTriangle(
    triangle: *const LocalTriangle,
    tile: *Tile,
    atlas: *Atlas,
) void {
    const e0 = triangle.e0;
    const e1 = triangle.e1;
    const e2 = triangle.e2;

    const coverage_bias = I3{
        e0.top_left_bias + e0.cons_bias,
        e1.top_left_bias + e1.cons_bias,
        e2.top_left_bias + e2.cons_bias,
    };

    const area = triangle.area;
    if (area == 0) return; // triangle is degenerate

    const inv_area = triangle.inv_area;

    const tx0_fx: i32 = (@as(i32, @intCast(tile.pos[0])) << SUBPIXEL_BITS) + HALF_SUBPIXEL;
    const ty0_fx: i32 = (@as(i32, @intCast(tile.pos[1])) << SUBPIXEL_BITS) + HALF_SUBPIXEL;

    const tile_size = tile.dimensions;

    // P: Edge values at tile origin, without fill-rule bias
    const w0_origin: i32 = e0.eval(tx0_fx, ty0_fx);
    const w1_origin: i32 = e1.eval(tx0_fx, ty0_fx);
    const w2_origin: i32 = e2.eval(tx0_fx, ty0_fx);

    // P: Integer edge stepping FOR coverage
    const px_step: i32 = 1 << SUBPIXEL_BITS; // 16
    const right_inc = I3{ e0.A * px_step, e1.A * px_step, e2.A * px_step };
    const down_inc = I3{ e0.B * px_step, e1.B * px_step, e2.B * px_step };

    var w_row = I3{ w0_origin, w1_origin, w2_origin };

    // P: Reciprocal depth at vertices.
    const q0: f32 = triangle.q0;
    const q1: f32 = triangle.q1;
    const q2: f32 = triangle.q2;

    // const avg_rec_depth: f32 = (q0 + q1 + q2) / 3.0;

    const tex_u: usize = @intCast(triangle.tex_u);
    var tex_v: usize = @intCast(triangle.tex_v);

    // P: Wireframe thickness
    // const base_thickness: f32 = @floatFromInt(50000 << SUBPIXEL_BITS);
    // const thickness: i32 = @intFromf32(base_thickness * avg_rec_depth);

    // P: Attribute values multiplied by reciprocal depth
    const uv0: UV = triangle.uv0;
    const uv1: UV = triangle.uv1;
    const uv2: UV = triangle.uv2;

    const uq0: f32 = uv0[0] * q0;
    const uq1: f32 = uv1[0] * q1;
    const uq2: f32 = uv2[0] * q2;

    const vq0: f32 = uv0[1] * q0;
    const vq1: f32 = uv1[1] * q1;
    const vq2: f32 = uv2[1] * q2;

    // P: Evaluate depth/uv interpolants once at tile origin
    // This is a 'base' for incremental stepping
    const w0_origin_f: f32 = @floatFromInt(w0_origin);
    const w1_origin_f: f32 = @floatFromInt(w1_origin);
    const w2_origin_f: f32 = @floatFromInt(w2_origin);

    // den_row is both the denominator of attribute interpolation
    // and the numerator of depth interpolation
    var den_row: f32 = w0_origin_f * q0 + w1_origin_f * q1 + w2_origin_f * q2;
    var u_num_row: f32 = w0_origin_f * uq0 + w1_origin_f * uq1 + w2_origin_f * uq2;
    var v_num_row: f32 = w0_origin_f * vq0 + w1_origin_f * vq1 + w2_origin_f * vq2;

    // P: Incremental values (constant x/y derivatives) (for depth/uv + mip level)
    const e0_a_f: f32 = @floatFromInt(e0.A);
    const e1_a_f: f32 = @floatFromInt(e1.A);
    const e2_a_f: f32 = @floatFromInt(e2.A);
    const e0_b_f: f32 = @floatFromInt(e0.B);
    const e1_b_f: f32 = @floatFromInt(e1.B);
    const e2_b_f: f32 = @floatFromInt(e2.B);

    const px_step_f: f32 = @floatFromInt(1 << SUBPIXEL_BITS);

    const den_dx: f32 = (e0_a_f * q0 + e1_a_f * q1 + e2_a_f * q2) * px_step_f;
    const den_dy: f32 = (e0_b_f * q0 + e1_b_f * q1 + e2_b_f * q2) * px_step_f;

    const u_num_dx: f32 = (e0_a_f * uq0 + e1_a_f * uq1 + e2_a_f * uq2) * px_step_f;
    const u_num_dy: f32 = (e0_b_f * uq0 + e1_b_f * uq1 + e2_b_f * uq2) * px_step_f;

    const v_num_dx: f32 = (e0_a_f * vq0 + e1_a_f * vq1 + e2_a_f * vq2) * px_step_f;
    const v_num_dy: f32 = (e0_b_f * vq0 + e1_b_f * vq1 + e2_b_f * vq2) * px_step_f;

    // P: Mip level selection
    const du_over_dx = (u_num_dx * den_row - u_num_row * den_dx) /
        (den_row * den_row);
    const du_over_dy = (u_num_dy * den_row - u_num_row * den_dy) /
        (den_row * den_row);
    const dv_over_dx = (v_num_dx * den_row - v_num_row * den_dx) /
        (den_row * den_row);
    const dv_over_dy = (v_num_dy * den_row - v_num_row * den_dy) /
        (den_row * den_row);

    const rho_x_2 = du_over_dx * du_over_dx + dv_over_dx * dv_over_dx;
    const rho_y_2 = du_over_dy * du_over_dy + dv_over_dy * dv_over_dy;
    const rho = std.math.sqrt(@max(rho_x_2, rho_y_2));
    const mip = mipFromRho(rho, 4);

    tex_v += mip * atlas.tex_h * atlas.block_count;

    const color_buf = tile.buf;
    const z_buf = tile.z_buf;
    const texels = atlas.atlas;
    const atlas_width = atlas.width;
    const atlas_height = atlas.height;

    // P: Stepping
    var y: usize = 0;
    while (y < tile_size) : ({
        y += 1;
        w_row += down_inc;
        den_row += den_dy;
        u_num_row += u_num_dy;
        v_num_row += v_num_dy;
    }) {
        const row_base: usize = y * tile_size;

        // Top-left rule and T-junction bias
        var w = w_row + coverage_bias;
        var den: f32 = den_row;
        var u_num: f32 = u_num_row;
        var v_num: f32 = v_num_row;

        var x: usize = 0;
        while (x < tile_size) : ({
            x += 1;
            w += right_inc;
            den += den_dx;
            u_num += u_num_dx;
            v_num += v_num_dx;
        }) {
            if ((w[0] | w[1] | w[2]) < 0) continue;

            const inv_z: f32 = den * inv_area;
            const idx: usize = row_base + x;

            if (inv_z <= z_buf[idx]) continue;
            z_buf[idx] = inv_z;

            // const fog_z: f32 = 1.0 / inv_z;
            // const f: f32 = fog.fogFactor(fog_z);

            // if (f <= 0.0) {
            //     color_buf[idx] = fog.color;
            //     continue;
            // }

            const u_f = u_num / den;
            const v_f = v_num / den;

            const u_i: i32 = @intFromFloat(@floor(u_f));
            const v_i: i32 = @intFromFloat(@floor(v_f));

            const mask_i: i32 = @intCast(TEX_TILE_SIZE - 1);
            const u_tile: usize = @intCast(u_i & mask_i);
            const v_tile: usize = @intCast(v_i & mask_i);

            const u: usize = tex_u + u_tile;
            const v: usize = tex_v + v_tile;

            const tex_idx: usize = std.math.clamp(
                u + v * atlas_width,
                0,
                atlas_width * atlas_height - 1,
            );

            color_buf[idx] = texels[tex_idx];

            // const texel = texels[tex_idx];
            // color_buf[idx] = if (f >= 1.0) texel else fog.blendFogARGB8(texel, f);
        }
    }
}

//// PRIMITIVE RASTERIZATION ///////////////////////////////////////////////////
pub inline fn renderQuadInTile(
    material: MaterialRef,
    vertices: []const ProjectedVertex,
    tile: *Tile,
    atlas: *Atlas,
) void {
    const tri0 = setupLocalTriangle(
        vertices[0],
        vertices[1],
        vertices[2],
        material.tex_u,
        material.tex_v,
    );
    const tri1 = setupLocalTriangle(
        vertices[0],
        vertices[2],
        vertices[3],
        material.tex_u,
        material.tex_v,
    );

    if (!triangleFullyOutsideTile(&tri0, tile)) rasterLocalTriangle(&tri0, tile, atlas);
    if (!triangleFullyOutsideTile(&tri1, tile)) rasterLocalTriangle(&tri1, tile, atlas);
}

pub inline fn renderPolygonInTile(
    material: MaterialRef,
    vertices: []const ProjectedVertex,
    tile: *Tile,
    atlas: *Atlas,
) void {
    std.debug.assert(vertices.len >= 3);
    std.debug.assert(vertices.len <= 9);

    const v0 = vertices[0];

    for (1..vertices.len - 1) |vert_i| {
        const tri = setupLocalTriangle(
            v0,
            vertices[vert_i],
            vertices[vert_i + 1],
            material.tex_u,
            material.tex_v,
        );

        if (!triangleFullyOutsideTile(&tri, tile)) rasterLocalTriangle(&tri, tile, atlas);
    }
}
