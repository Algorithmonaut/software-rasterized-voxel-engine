const Tile = @import("tile.zig");
const std = @import("std");
const cfg = @import("config.zig");
const Float = cfg.Float;
const Int = cfg.Int;
const Vec3f = cfg.Vec3f;
const Vec4f = cfg.Vec4f;
const Vec3i = cfg.Vec3i;
const Vec4i = cfg.Vec4i;
const mat = @import("matrix.zig");
const ctx = @import("context.zig");
const tex = @import("textures.zig");

pub const RasterTriangle = struct {
    v0: @Vector(2, Int),
    v0_uv: @Vector(2, usize),
    v0_rec_z: f32,
    v1: @Vector(2, Int),
    v1_uv: @Vector(2, usize),
    v1_rec_z: f32,
    v2: @Vector(2, Int),
    v2_uv: @Vector(2, usize),
    v2_rec_z: f32,

    const Edge = struct {
        // NOTE: Edge function can be refactored: E(x,y) = Ax + By + C with A B C constants
        A: i32,
        B: i32,
        C: i32, // WARN: Change to i64 if overflow

        bias: i32, // This is used for the top left rule

        /// Evaluate the point (x, y) against the edge
        inline fn eval(self: Edge, x: i32, y: i32) i32 {
            return self.A * x + self.B * y + self.C; // WARN: Cast to i64 if overflow
        }
    };

    /// Max is exclusive
    pub inline fn bounding_box(self: RasterTriangle) struct {
        min_x: usize,
        max_x: usize,
        min_y: usize,
        max_y: usize,
    } {
        const a = self.v0;
        const b = self.v1;
        const c = self.v2;

        const min_x = @min(a[0], b[0], c[0]);
        const max_x_incl = @max(a[0], b[0], c[0]);

        const min_y = @min(a[1], b[1], c[1]);
        const max_y_incl = @max(a[1], b[1], c[1]);

        // Clamp min to [0, width/height] (min is inclusive)
        const min_x_c = std.math.clamp(min_x, 0, cfg.width);
        const min_y_c = std.math.clamp(min_y, 0, cfg.height);

        // Convert inclusive max -> exclusive max, then clamp to [0, width/height]
        const max_x_excl = std.math.clamp(max_x_incl + 1, 0, cfg.width);
        const max_y_excl = std.math.clamp(max_y_incl + 1, 0, cfg.height);

        return .{
            .min_x = min_x_c,
            .max_x = max_x_excl,
            .min_y = min_y_c,
            .max_y = max_y_excl,
        };
    }

    /// Create Edge from two (oriented) vertex
    inline fn make_edge(a: @Vector(2, i32), b: @Vector(2, i32)) Edge {
        const x0 = a[0];
        const y0 = a[1];
        const x1 = b[0];
        const y1 = b[1];
        const dy = y1 - y0;
        const dx = x1 - x0;

        const is_top_left: bool = (dy > 0) or (dy == 0 and dx < 0);

        // E(x,y) = (y1 - y0)*x + (x0 - x1)*y + (y0*x1 - x0*y1)
        return .{
            .A = y1 - y0,
            .B = x0 - x1,
            .C = y0 * x1 - x0 * y1,
            .bias = if (is_top_left) 0 else -1,
        };
    }

    pub inline fn render_triangle_in_tile(self: *const RasterTriangle, tile: *Tile.Tile) void {
        const a = self.v0;
        const b = self.v1;
        const c = self.v2;

        const e0 = make_edge(c, b);
        const e1 = make_edge(a, c);
        const e2 = make_edge(b, a);
        const area = e0.eval(a[0], a[1]);

        if (area < 0) return; // backface culling

        const inv_area = 1 / @as(Float, @floatFromInt(area));

        const tx0: i32 = @intCast(tile.pos[0]);
        const ty0: i32 = @intCast(tile.pos[1]);

        // P: Evaluate edges at top-left of tile
        const w0_row = e0.eval(tx0, ty0);
        const w1_row = e1.eval(tx0, ty0);
        const w2_row = e2.eval(tx0, ty0);
        var w_row = Vec3i{ w0_row, w1_row, w2_row };

        // P: Reciprocal depth at the vertices
        const q0: Float = self.v0_rec_z;
        const q1: Float = self.v1_rec_z;
        const q2: Float = self.v2_rec_z;

        const Uvf = @Vector(2, Float);

        const uv0f: Uvf = @floatFromInt(self.v0_uv);
        const uv1f: Uvf = @floatFromInt(self.v1_uv);
        const uv2f: Uvf = @floatFromInt(self.v2_uv);

        const uv0q: Uvf = uv0f * @as(Uvf, @splat(q0));
        const uv1q: Uvf = uv1f * @as(Uvf, @splat(q1));
        const uv2q: Uvf = uv2f * @as(Uvf, @splat(q2));

        // P: Step vectors
        const right_inc = Vec3i{ e0.A, e1.A, e2.A };
        const down_inc = Vec3i{ e0.B, e1.B, e2.B };

        // P: Main loop
        var y: usize = 0;
        while (y < cfg.tile_dimensions) : (y += 1) {
            const z_row_base: usize = y * cfg.tile_dimensions; // base addr in z-buffer for row
            const buf_row_base: usize = y * cfg.tile_dimensions; // base addr in fb for row

            var w = w_row;

            var x: usize = 0;
            while (x < cfg.tile_dimensions) : (x += 1) {
                // Step right (still runs if z-buf test fails)
                defer w += right_inc;
                if (w[0] + e0.bias >= 0 and w[1] + e1.bias >= 0 and w[2] + e2.bias >= 0) {
                    const wf: Vec3f = @floatFromInt(w);
                    const den_scaled = (wf[0] * q0 + wf[1] * q1 + wf[2] * q2);
                    const inv_z = den_scaled * inv_area;

                    const z_idx = z_row_base + x;
                    if (inv_z <= tile.z_buf[z_idx]) continue;
                    tile.z_buf[z_idx] = inv_z;

                    const uv_num = uv0q * @as(Uvf, @splat(wf[0])) +
                        uv1q * @as(Uvf, @splat(wf[1])) +
                        uv2q * @as(Uvf, @splat(wf[2]));

                    const rcp_den: Float = 1.0 / den_scaled;
                    const uv = uv_num * @as(Uvf, @splat(rcp_den));

                    const max_u_f: Float = @floatFromInt(cfg.atlas_w - 1);
                    const max_v_f: Float = @floatFromInt(cfg.atlas_h - 1);

                    const u_f = std.math.clamp(uv[0], 0.0, max_u_f);
                    const v_f = std.math.clamp(uv[1], 0.0, max_v_f);

                    const u: usize = @intFromFloat(u_f + 0.5);
                    const v: usize = @intFromFloat(v_f + 0.5);

                    const base: usize = (u + v * cfg.atlas_w);
                    const argb = ctx.atlas.atlas[base];
                    tile.buf[buf_row_base + x] = argb;
                }
            }

            // Step down
            w_row += down_inc;
        }
    }
};

pub const Triangle = struct {
    v0: @Vector(4, f32),
    v0_uv: @Vector(2, usize),
    v1: @Vector(4, f32),
    v1_uv: @Vector(2, usize),
    v2: @Vector(4, f32),
    v2_uv: @Vector(2, usize),

    pub inline fn gen_raster_triangle(
        self: *Triangle,
    ) ?RasterTriangle {
        // P: Camera space -> clip space
        const verts = .{ &self.v0, &self.v1, &self.v2 };
        var verts_h: [3]Vec4f = undefined;
        var inv_ws: Vec3f = undefined;

        inline for (verts, 0..) |vp, i| {
            var v = Vec4f{ vp.*[0], vp.*[1], vp.*[2], 1.0 };
            v = ctx.projection_matrix.mul_vec(v);

            const clip_w = v[3];
            const inv_w = 1.0 / clip_w;
            inv_ws[i] = inv_w;
            v = v * @as(Vec4f, @splat(inv_w));

            verts_h[i] = v;
        }

        const v0 = verts_h[0];
        const v1 = verts_h[1];
        const v2 = verts_h[2];

        // Basic clipping
        if ((v0[0] > 1 and v1[0] > 1 and v2[0] > 1) or
            v0[0] < -1 and v1[0] < -1 and v2[0] < -1) return null;

        if ((v0[1] > 1 and v1[1] > 1 and v2[1] > 1) or
            v0[1] < -1 and v1[1] < -1 and v2[1] < -1) return null;

        if ((v0[2] > 1 and v1[2] > 1 and v2[2] > 1) or
            v0[2] < 0 or v1[2] < 0 or v2[2] < 0) return null;

        // P: Clip -> raster
        const fw: Float = cfg.width;
        const fh: Float = cfg.height;

        const a = @Vector(2, Int){
            @intFromFloat((v0[0] + 1.0) * 0.5 * fw + 0.5),
            @intFromFloat((1 - (v0[1] + 1.0) * 0.5) * fh + 0.5),
        };

        const b = @Vector(2, Int){
            @intFromFloat((v1[0] + 1.0) * 0.5 * fw + 0.5),
            @intFromFloat((1 - (v1[1] + 1.0) * 0.5) * fh + 0.5),
        };

        const c = @Vector(2, Int){
            @intFromFloat((v2[0] + 1.0) * 0.5 * fw + 0.5),
            @intFromFloat((1 - (v2[1] + 1.0) * 0.5) * fh + 0.5),
        };

        return .{
            .v0 = a,
            .v1 = b,
            .v2 = c,
            .v0_rec_z = inv_ws[0],
            .v1_rec_z = inv_ws[1],
            .v2_rec_z = inv_ws[2],
            .v0_uv = self.v0_uv,
            .v1_uv = self.v1_uv,
            .v2_uv = self.v2_uv,
        };
    }
};
