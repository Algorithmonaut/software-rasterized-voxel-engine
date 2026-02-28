const Framebuffer = @import("framebuffer.zig").Framebuffer;
const Tile = @import("tile.zig");
const std = @import("std");
const cfg = @import("config.zig");
const float = cfg.float;
const int = cfg.int;
const vec3f = cfg.vec3f;
const vec4f = cfg.vec4f;
const vec3i = cfg.vec3i;
const vec4i = cfg.vec4i;
const mat = @import("matrix.zig");
const ctx = @import("context.zig");
const tex = @import("textures.zig");

pub const RasterTriangle = struct {
    v0: @Vector(2, int),
    v0_uv: @Vector(2, usize),
    v0_rec_z: f32,
    v1: @Vector(2, int),
    v1_uv: @Vector(2, usize),
    v1_rec_z: f32,
    v2: @Vector(2, int),
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

        const inv_area = 1 / @as(float, @floatFromInt(area));

        const tx0: i32 = @intCast(tile.pos[0]);
        const ty0: i32 = @intCast(tile.pos[1]);

        // P: Evaluate edges at top-left of tile
        const w0_row = e0.eval(tx0, ty0);
        const w1_row = e1.eval(tx0, ty0);
        const w2_row = e2.eval(tx0, ty0);
        var w_row = vec3i{ w0_row, w1_row, w2_row };

        // P: Reciprocal depth at the vertices
        const q0: float = self.v0_rec_z;
        const q1: float = self.v1_rec_z;
        const q2: float = self.v2_rec_z;

        const Uvf = @Vector(2, float);

        const uv0f: Uvf = @floatFromInt(self.v0_uv);
        const uv1f: Uvf = @floatFromInt(self.v1_uv);
        const uv2f: Uvf = @floatFromInt(self.v2_uv);

        const uv0q: Uvf = uv0f * @as(Uvf, @splat(q0));
        const uv1q: Uvf = uv1f * @as(Uvf, @splat(q1));
        const uv2q: Uvf = uv2f * @as(Uvf, @splat(q2));

        // P: Step vectors
        const right_inc = vec3i{ e0.A, e1.A, e2.A };
        const down_inc = vec3i{ e0.B, e1.B, e2.B };

        // P: Main loop
        var y: usize = 0;
        while (y < cfg.tile_dimensions) : (y += 1) {
            const z_row_base: usize = y * cfg.tile_dimensions; // base addr in z-buffer for row
            const buf_row_base: usize = y * cfg.tile_dimensions; // base addr in fb for row

            var w = w_row;

            var x: usize = 0;
            while (x < cfg.tile_dimensions) : (x += 1) {
                if (w[0] + e0.bias >= 0 and w[1] + e1.bias >= 0 and w[2] + e2.bias >= 0) {
                    const wf: vec3f = @floatFromInt(w);
                    const den_scaled = (wf[0] * q0 + wf[1] * q1 + wf[2] * q2);
                    const inv_z = den_scaled * inv_area;

                    const z_idx = z_row_base + x;
                    if (inv_z <= tile.z_buf[z_idx]) continue;
                    tile.z_buf[z_idx] = inv_z;

                    const uv_num = uv0q * @as(Uvf, @splat(wf[0])) +
                        uv1q * @as(Uvf, @splat(wf[1])) +
                        uv2q * @as(Uvf, @splat(wf[2]));

                    const rcp_den: float = 1.0 / den_scaled;
                    const uv = uv_num * @as(Uvf, @splat(rcp_den));

                    const max_u_f: float = @floatFromInt(cfg.atlas_w - 1);
                    const max_v_f: float = @floatFromInt(cfg.atlas_h - 1);

                    const u_f = std.math.clamp(uv[0], 0.0, max_u_f);
                    const v_f = std.math.clamp(uv[1], 0.0, max_v_f);

                    const u: usize = @intFromFloat(u_f);
                    const v: usize = @intFromFloat(v_f);

                    const base: usize = (u + v * cfg.atlas_w);
                    const argb = ctx.atlas.atlas[base];
                    tile.buf[buf_row_base + x] = argb;
                }

                // Step right
                w += right_inc;
            }

            // Step down
            w_row += down_inc;
        }
    }

    pub inline fn render(self: *const RasterTriangle, fb: *Framebuffer) void {
        const a = self.v0;
        const b = self.v1;
        const c = self.v2;

        // P: Compute the edges
        const e0 = make_edge(c, b);
        const e1 = make_edge(a, c);
        const e2 = make_edge(b, a);

        const area = e0.eval(a[0], a[1]);

        if (area < 0) return; // backface culling

        const inv_area = 1 / @as(float, @floatFromInt(area));

        // P: Compute the bbox and clip it to the viewport
        var x_min_i: i32 = @min(a[0], b[0], c[0]);
        var x_max_i: i32 = @max(a[0], b[0], c[0]);
        var y_min_i: i32 = @min(a[1], b[1], c[1]);
        var y_max_i: i32 = @max(a[1], b[1], c[1]);

        const width: i32 = @intCast(cfg.width);
        const height: i32 = @intCast(cfg.height);

        x_min_i = std.math.clamp(x_min_i, 0, width - 1);
        x_max_i = std.math.clamp(x_max_i, 0, width - 1);
        y_min_i = std.math.clamp(y_min_i, 0, height - 1);
        y_max_i = std.math.clamp(y_max_i, 0, height - 1);

        // P: Evaluate edges at top-left of bbox
        const w0_row = e0.eval(x_min_i, y_min_i);
        const w1_row = e1.eval(x_min_i, y_min_i);
        const w2_row = e2.eval(x_min_i, y_min_i);
        var w_row = vec3i{ w0_row, w1_row, w2_row };

        // P: Convert bbox to usize for incremental stepping
        const x_min: usize = @intCast(x_min_i);
        const x_max: usize = @intCast(x_max_i);
        const y_min: usize = @intCast(y_min_i);
        const y_max: usize = @intCast(y_max_i);

        // P: Reciprocal depth at the vertices
        const q0: float = self.v0_rec_z;
        const q1: float = self.v1_rec_z;
        const q2: float = self.v2_rec_z;

        const Uvf = @Vector(2, float);

        const uv0f: Uvf = @floatFromInt(self.v0_uv);
        const uv1f: Uvf = @floatFromInt(self.v1_uv);
        const uv2f: Uvf = @floatFromInt(self.v2_uv);

        const uv0q: Uvf = uv0f * @as(Uvf, @splat(q0));
        const uv1q: Uvf = uv1f * @as(Uvf, @splat(q1));
        const uv2q: Uvf = uv2f * @as(Uvf, @splat(q2));

        // P: Step vectors
        const right_inc = vec3i{ e0.A, e1.A, e2.A };
        const down_inc = vec3i{ e0.B, e1.B, e2.B };

        // P: Main loop
        var y: usize = y_min;
        while (y <= y_max) : (y += 1) {
            const line = fb.get_scanline(y);
            const z_row_base: usize = y * cfg.width;

            var w = w_row;

            var x: usize = x_min;
            while (x <= x_max) : (x += 1) {
                if (w[0] + e0.bias >= 0 and w[1] + e1.bias >= 0 and w[2] + e2.bias >= 0) {
                    const wf: vec3f = @floatFromInt(w);
                    const den_scaled = (wf[0] * q0 + wf[1] * q1 + wf[2] * q2);
                    const inv_z = den_scaled * inv_area;

                    const z_idx = z_row_base + x;
                    if (inv_z <= fb.z_buffer[z_idx]) continue;
                    fb.z_buffer[z_idx] = inv_z;

                    const uv_num = uv0q * @as(Uvf, @splat(wf[0])) +
                        uv1q * @as(Uvf, @splat(wf[1])) +
                        uv2q * @as(Uvf, @splat(wf[2]));

                    const rcp_den: float = 1.0 / den_scaled;
                    const uv = uv_num * @as(Uvf, @splat(rcp_den));

                    const max_u_f: float = @floatFromInt(cfg.atlas_w - 1);
                    const max_v_f: float = @floatFromInt(cfg.atlas_h - 1);

                    const u_f = std.math.clamp(uv[0], 0.0, max_u_f);
                    const v_f = std.math.clamp(uv[1], 0.0, max_v_f);

                    const u: usize = @intFromFloat(u_f);
                    const v: usize = @intFromFloat(v_f);

                    const base: usize = (u + v * cfg.atlas_w);
                    const argb = ctx.atlas.atlas[base];
                    line[x] = argb;
                }

                // Step right
                w += right_inc;
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
        var verts_h: [3]vec4f = undefined;
        var inv_ws: vec3f = undefined;

        inline for (verts, 0..) |vp, i| {
            var v = vec4f{ vp.*[0], vp.*[1], vp.*[2], 1.0 };
            v = ctx.projection_matrix.mul_vec(v);

            const clip_w = v[3];
            const inv_w = 1.0 / clip_w;
            inv_ws[i] = inv_w;
            v = v * @as(vec4f, @splat(inv_w));

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

        if ((v0[2] > 1 or v1[2] > 1 or v2[2] > 1) or
            v0[2] < 0 or v1[2] < 0 or v2[2] < 0) return null;

        // P: Clip -> raster
        const fw: float = cfg.width;
        const fh: float = cfg.height;

        const a = @Vector(2, int){
            @intFromFloat((v0[0] + 1.0) * 0.5 * fw + 0.5),
            @intFromFloat((1 - (v0[1] + 1.0) * 0.5) * fh + 0.5),
        };

        const b = @Vector(2, int){
            @intFromFloat((v1[0] + 1.0) * 0.5 * fw + 0.5),
            @intFromFloat((1 - (v1[1] + 1.0) * 0.5) * fh + 0.5),
        };

        const c = @Vector(2, int){
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
