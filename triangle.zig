const Framebuffer = @import("framebuffer.zig").Framebuffer;
const std = @import("std");
const cfg = @import("config.zig");
const float = cfg.f;
const int = cfg.i;

pub const Triangle = struct {
    v0: @Vector(4, f32),
    v0_col: u32,
    v1: @Vector(4, f32),
    v1_col: u32,
    v2: @Vector(4, f32),
    v2_col: u32,

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

    inline fn xrgb_to_vec3(c: u32) @Vector(3, u8) {
        return .{ @truncate(c >> 16), @truncate(c >> 8), @truncate(c) };
    }

    inline fn vec3_to_xrgb(c: @Vector(3, u8)) u32 {
        return @as(u32, 0xFF) << 24 |
            @as(u32, c[0]) << 16 |
            @as(u32, c[1]) << 8 |
            @as(u32, c[2]);
    }

    /// Project the triangle from camera space to screen space
    inline fn camera_to_screen(self: *Triangle) void {
        const vertices = .{ &self.v0, &self.v1, &self.v2 };

        inline for (vertices) |v| {
            const z_inv = 1 / v.*[2];
            v.*[0] *= z_inv;
            v.*[1] *= z_inv;
        }
    }

    inline fn edge(a: @Vector(2, i32), b: @Vector(2, i32), p: @Vector(2, i32)) i32 {
        return (p[0] - a[0]) * (b[1] - a[1]) - (p[1] - a[1]) * (b[0] - a[0]);
    }

    /// Render a triangle that is IN camera space
    pub inline fn render_triangle(self: *Triangle, fb: *Framebuffer) void {
        const inv_w = 1 / @as(float, @floatFromInt(cfg.width));
        const inv_h = 1 / @as(float, @floatFromInt(cfg.height));

        const bias = @Vector(4, float){ 0.5, 0.5, 0, 0 };
        const scale = @Vector(4, float){ inv_w, inv_h, 1.0, 1.0 };

        const verts = .{ &self.v0, &self.v1, &self.v2 };

        // P: Project the vertices from camera space to screen space
        inline for (verts) |vp| {
            var v = vp.*; // NOTE: Local copy in register, so we only do one store and one load
            const inv_z = 1 / v[2];

            // Perspective divide
            v *= @Vector(4, float){ -inv_z, -inv_z, 1.0, 1.0 };

            // Screen -> NDC
            v = @mulAdd(@Vector(4, float), v, scale, bias);

            vp.* = v;
        }

        // NDC -> raster
        // NOTE: We add 0.5 such that we test against the center of the pixel, not its top left
        const a = @Vector(2, int){
            @intFromFloat(self.v0[0] * cfg.width + 0.5),
            @intFromFloat((1 - self.v0[1]) * cfg.height + 0.5),
        };

        const b = @Vector(2, int){
            @intFromFloat(self.v1[0] * cfg.width + 0.5),
            @intFromFloat((1 - self.v1[1]) * cfg.height + 0.5),
        };

        const c = @Vector(2, int){
            @intFromFloat(self.v2[0] * cfg.width + 0.5),
            @intFromFloat((1 - self.v2[1]) * cfg.height + 0.5),
        };

        const tri_area = edge(a, b, c);

        // Doing backface culling instead

        if (tri_area < 0) return;

        // If edge func is neg, then the triangle is oriented clockwise.
        // Swap any two vertices to reorient the triangle counter-clockwise.
        // if (tri_area < 0) {
        //     const tmp = b;
        //     b = c;
        //     c = tmp;
        //     tri_area = -tri_area;
        // }

        const inv_tri_area_f32 = 1 / @as(float, @floatFromInt(tri_area));

        // P: Compute the bbox and clip it to the viewport
        var x_min_i: i32 = @min(a[0], b[0], c[0]);
        var x_max_i: i32 = @max(a[0], b[0], c[0]);
        var y_min_i: i32 = @min(a[1], b[1], c[1]);
        var y_max_i: i32 = @max(a[1], b[1], c[1]);

        const w: i32 = @intCast(fb.width);
        const h: i32 = @intCast(fb.height);

        // Reject if the triangle is out of the viewport
        if (x_max_i < 0 or y_max_i < 0 or x_min_i >= w or y_min_i >= h) return;

        // Clamp the bounding box to the viewport
        x_min_i = std.math.clamp(x_min_i, 0, w - 1);
        x_max_i = std.math.clamp(x_max_i, 0, w - 1);
        y_min_i = std.math.clamp(y_min_i, 0, h - 1);
        y_max_i = std.math.clamp(y_max_i, 0, h - 1);

        // P: Compute the edges
        const e0 = make_edge(a, b);
        const e1 = make_edge(b, c);
        const e2 = make_edge(c, a);

        // Evaluate edges at top-left of bbox
        var w0_row = e0.eval(x_min_i, y_min_i);
        var w1_row = e1.eval(x_min_i, y_min_i);
        var w2_row = e2.eval(x_min_i, y_min_i);

        // P: Decompose vertex colors into f32 channels
        const v0_c_f32 = @as(@Vector(3, float), @floatFromInt(xrgb_to_vec3(self.v0_col)));
        const v1_c_f32 = @as(@Vector(3, float), @floatFromInt(xrgb_to_vec3(self.v1_col)));
        const v2_c_f32 = @as(@Vector(3, float), @floatFromInt(xrgb_to_vec3(self.v2_col)));

        // P: Convert bbox to usize for incremental stepping
        const x_min: usize = @intCast(x_min_i);
        const x_max: usize = @intCast(x_max_i);
        const y_min: usize = @intCast(y_min_i);
        const y_max: usize = @intCast(y_max_i);

        // P: Main loop
        var y: usize = y_min;
        while (y <= y_max) : (y += 1) {
            const line = fb.get_scanline(y);

            var w0: i32 = w0_row;
            var w1: i32 = w1_row;
            var w2: i32 = w2_row;

            var x: usize = x_min;

            while (x <= x_max) : (x += 1) {
                // If the point is inside the triangle
                if (w0 + e0.bias >= 0 and w1 + e1.bias >= 0 and w2 + e2.bias >= 0) {
                    const beta = @as(float, @floatFromInt(w1)) * inv_tri_area_f32;
                    const gamma = @as(float, @floatFromInt(w2)) * inv_tri_area_f32;
                    const alpha = 1 - beta - gamma;

                    const inv_z: float = 1 / self.v0[2] * alpha + 1 / self.v1[2] * beta + 1 / self.v2[2] * gamma;

                    if (inv_z <= fb.z_buffer[x + cfg.width * y]) continue;

                    fb.z_buffer[x + cfg.width * y] = inv_z;

                    const rgb: @Vector(3, float) = v0_c_f32 * @as(@Vector(3, float), @splat(alpha)) +
                        v1_c_f32 * @as(@Vector(3, float), @splat(beta)) +
                        v2_c_f32 * @as(@Vector(3, float), @splat(gamma));

                    const rgb_u8: @Vector(3, u8) = @intFromFloat(rgb);

                    const out_color: u32 = vec3_to_xrgb(rgb_u8);

                    line[x] = out_color;
                }

                // Step right
                w0 += e0.A;
                w1 += e1.A;
                w2 += e2.A;
            }

            // Step down
            w0_row += e0.B;
            w1_row += e1.B;
            w2_row += e2.B;
        }
    }
};
