const std = @import("std");
const types = @import("../types.zig");
const helpers = @import("../helpers.zig");
const constants = @import("../constants.zig");
const textures = @import("../assets/textures.zig");

const UV = types.UV;
const Face = types.Face;
const BlockId = types.BlockId;
const PrimitiveBuilder = @import("../PrimitiveBuilder.zig");
const ProjectedVertex = PrimitiveBuilder.ProjectedVertex;
const MaterialRef = PrimitiveBuilder.MaterialRef;
const PrimitiveRef = PrimitiveBuilder.PrimitiveRef;

const Tile = @import("../tile.zig").Tile;
const TilePool = @import("../tile.zig").TilePool;

const I3 = types.I3;
const FX2 = types.FX2;
const TEX_TILE_BITS: usize = 4; // log2(16)
const TEX_SIZE = constants.TEX_SIZE;
const SUBPIXEL_BITS = constants.SUBPIXEL_BITS;
const SUBPIXEL_SCALE = constants.SUBPIXEL_SCALE;
const HALF_SUBPIXEL = constants.HALF_SUBPIXEL;

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

// const Fog = struct {
//     start: f32,
//     end: f32,
//
//     pub inline fn amount(self: Fog, d: f32) f32 {
//         const denom = self.end - self.start;
//         if (denom <= 0.0) return 1.0;
//
//         return helpers.clamp01((d - self.start) / denom);
//     }
// };

// const fog = Fog{ .start = 600, .end = 700 };

// inline fn lerpU8(a: u8, b: u8, t: f32) u8 {
//     const af: f32 = @floatFromInt(a);
//     const bf: f32 = @floatFromInt(b);
//     return @intFromFloat(af + (bf - af) * t);
// }
//
// inline fn blendFogARGB8(src: u32, fog_color: u32, t: f32) u32 {
//     const src_a: u8 = @intCast((src >> 24) & 0xff);
//     const src_r: u8 = @intCast((src >> 16) & 0xff);
//     const src_g: u8 = @intCast((src >> 8) & 0xff);
//     const src_b: u8 = @intCast(src & 0xff);
//
//     const fog_r: u8 = @intCast((fog_color >> 16) & 0xff);
//     const fog_g: u8 = @intCast((fog_color >> 8) & 0xff);
//     const fog_b: u8 = @intCast(fog_color & 0xff);
//
//     const r = lerpU8(src_r, fog_r, t);
//     const g = lerpU8(src_g, fog_g, t);
//     const b = lerpU8(src_b, fog_b, t);
//
//     return (@as(u32, src_a) << 24) |
//         (@as(u32, r) << 16) |
//         (@as(u32, g) << 8) |
//         @as(u32, b);
// }

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

/// Builds the implicit line equation for the directed edge `a -> b`
inline fn makeEdge(a: @Vector(2, i32), b: @Vector(2, i32)) Edge {
    const x0 = a[0];
    const y0 = a[1];
    const x1 = b[0];
    const y1 = b[1];

    const dx = x1 - x0;
    const dy = y1 - y0;

    const A: i32 = dy;
    const B: i32 = -dx;
    const C: i32 = y0 * x1 - x0 * y1;

    const is_top_left: bool = (dy > 0) or (dy == 0 and dx < 0);

    // This is far from being a good solution, but it is my only solution
    const conservative_radius: i32 = 1;
    const conservative_bias: i32 =
        conservative_radius * @as(i32, @intCast(@abs(A) + @abs(B)));

    return .{
        .A = A,
        .B = B,
        .C = C,
        .top_left_bias = if (is_top_left) 0 else -1,
        .cons_bias = conservative_bias,
    };
}

//// TRIANGLE SETUP ////////////////////////////////////////////////////////////

const LocalTriangle = struct {
    v0: FX2,
    v1: FX2,
    v2: FX2,

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

    id: BlockId,
    face: Face,
};

inline fn setupLocalTriangle(
    a: ProjectedVertex,
    b: ProjectedVertex,
    c: ProjectedVertex,
    id: BlockId,
    face: Face,
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

        .id = id,
        .face = face,
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
    sky_rows: []u32,
    // comptime alpha_test: bool,
) void {
    _ = sky_rows;

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

    // Edge values at tile origin, without fill-rule bias
    const w0_origin: i32 = e0.eval(tx0_fx, ty0_fx);
    const w1_origin: i32 = e1.eval(tx0_fx, ty0_fx);
    const w2_origin: i32 = e2.eval(tx0_fx, ty0_fx);

    // Integer edge stepping FOR coverage
    const px_step: i32 = 1 << SUBPIXEL_BITS; // 16
    const right_inc = I3{ e0.A * px_step, e1.A * px_step, e2.A * px_step };
    const down_inc = I3{ e0.B * px_step, e1.B * px_step, e2.B * px_step };

    var w_row = I3{ w0_origin, w1_origin, w2_origin };

    // Reciprocal depth at vertices.
    const q0: f32 = triangle.q0;
    const q1: f32 = triangle.q1;
    const q2: f32 = triangle.q2;

    // Attribute values multiplied by reciprocal depth
    const uv0: UV = triangle.uv0;
    const uv1: UV = triangle.uv1;
    const uv2: UV = triangle.uv2;

    const uq0: f32 = uv0[0] * q0;
    const uq1: f32 = uv1[0] * q1;
    const uq2: f32 = uv2[0] * q2;

    const vq0: f32 = uv0[1] * q0;
    const vq1: f32 = uv1[1] * q1;
    const vq2: f32 = uv2[1] * q2;

    // Evaluate depth/uv interpolants once at tile origin
    // This is a 'base' for incremental stepping
    const w0_origin_f: f32 = @floatFromInt(w0_origin);
    const w1_origin_f: f32 = @floatFromInt(w1_origin);
    const w2_origin_f: f32 = @floatFromInt(w2_origin);

    // den_row is both the denominator of attribute interpolation
    // and the numerator of depth interpolation
    var den_row: f32 = w0_origin_f * q0 + w1_origin_f * q1 + w2_origin_f * q2;
    var u_num_row: f32 = w0_origin_f * uq0 + w1_origin_f * uq1 + w2_origin_f * uq2;
    var v_num_row: f32 = w0_origin_f * vq0 + w1_origin_f * vq1 + w2_origin_f * vq2;

    // Incremental values (constant x/y derivatives) (for depth/uv + mip level)
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

    // Mip level selection
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

    const mip_level: usize = @intCast(mip);

    const mip_shift_i32: std.math.Log2Int(i32) = @intCast(mip_level);
    const row_shift: std.math.Log2Int(usize) = @intCast(TEX_TILE_BITS - mip_level);

    // mip 0 -> mask 15, row shift 4
    // mip 1 -> mask 7,  row shift 3
    // mip 2 -> mask 3,  row shift 2
    // mip 3 -> mask 1,  row shift 1
    // mip 4 -> mask 0,  row shift 0
    const mip_mask_i32: i32 = (@as(i32, TEX_SIZE) >> mip_shift_i32) - 1;

    const texels = textures.getTextureData(triangle.id, triangle.face, mip);

    const color_buf = tile.buf;
    const z_buf = tile.z_buf;

    // Stepping
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

        // const fog_color = sky_rows[tile.pos[1] + y];

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

            // const fog_z: f32 = 1.0 / inv_z;
            // const f: f32 = fog.fogFactor(fog_z);

            // if (f <= 0.0) {
            //     color_buf[idx] = fog.color;
            //     continue;
            // }

            // One reciprocal instead of two float divisions.
            const inv_den_for_uv: f32 = 1.0 / den;

            // Base-level texel coordinates.
            const u_base_i: i32 = @intFromFloat(@floor(u_num * inv_den_for_uv));
            const v_base_i: i32 = @intFromFloat(@floor(v_num * inv_den_for_uv));

            // Convert base-level texel coordinate to selected mip coordinate:
            //
            // mip 0: u >> 0
            // mip 1: u >> 1
            // mip 2: u >> 2
            // mip 3: u >> 3
            // mip 4: u >> 4
            const u_mip_i: i32 = u_base_i >> mip_shift_i32;
            const v_mip_i: i32 = v_base_i >> mip_shift_i32;

            // Power-of-two wrapping inside selected mip.
            const u: usize = @intCast(u_mip_i & mip_mask_i32);
            const v: usize = @intCast(v_mip_i & mip_mask_i32);

            // Since mip width is power-of-two:
            // pixel_idx = u + v * mip_width
            // becomes:
            // pixel_idx = u + (v << row_shift)
            const pixel_idx: usize = u + (v << row_shift);

            const texel = texels[pixel_idx];

            if (((texel >> 24) & 0xFF) == 0) continue;

            color_buf[idx] = texel;
            z_buf[idx] = inv_z;
        }
    }
}

//// PRIMITIVE RASTERIZATION ///////////////////////////////////////////////////

pub inline fn renderQuadInTile(
    material: MaterialRef,
    vertices: []const ProjectedVertex,
    tile: *Tile,
    sky_rows: []u32,
) void {
    const tri0 = setupLocalTriangle(
        vertices[0],
        vertices[1],
        vertices[2],
        material.id,
        material.face,
    );
    const tri1 = setupLocalTriangle(
        vertices[0],
        vertices[2],
        vertices[3],
        material.id,
        material.face,
    );

    if (!triangleFullyOutsideTile(&tri0, tile)) rasterLocalTriangle(&tri0, tile, sky_rows);
    if (!triangleFullyOutsideTile(&tri1, tile)) rasterLocalTriangle(&tri1, tile, sky_rows);
}

pub inline fn renderPolygonInTile(
    material: MaterialRef,
    vertices: []const ProjectedVertex,
    tile: *Tile,
    sky_rows: []u32,
) void {
    std.debug.assert(vertices.len >= 3);
    std.debug.assert(vertices.len <= 9);

    const v0 = vertices[0];

    for (1..vertices.len - 1) |vert_i| {
        const tri = setupLocalTriangle(
            v0,
            vertices[vert_i],
            vertices[vert_i + 1],
            material.id,
            material.face,
        );

        if (!triangleFullyOutsideTile(&tri, tile)) rasterLocalTriangle(&tri, tile, sky_rows);
    }
}
