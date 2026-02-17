const std = @import("std");
const ctx = @import("context.zig");

pub const Triangle = struct {
    v0: @Vector(2, i32),
    v0_col: u32,
    v1: @Vector(2, i32),
    v1_col: u32,
    v2: @Vector(2, i32),
    v2_col: u32,

    const Edge = struct {
        // Edge function can be refactored: E(x,y) = Ax + By + C with A B C constants
        A: i32,
        B: i32,
        C: i32, // WARN: Change to i64 if overflow

        // Evaluate the point (x, y) against the edge
        inline fn eval(self: Edge, x: i32, y: i32) i32 {
            return self.A * x + self.B * y + self.C; // WARN: Cast to i64 if overflow
        }
    };

    // Create edge from two (oriented) vertex
    inline fn make_edge(a: @Vector(2, i32), b: @Vector(2, i32)) Edge {
        const x0 = a[0];
        const y0 = a[1];
        const x1 = b[0];
        const y1 = b[1];

        // The triangles are defined counter-clockwise, take the opposite if winding
        // order changes later
        // E(x,y) = (y1 - y0)*x + (x0 - x1)*y + (y0*x1 - x0*y1)

        return .{
            .A = y1 - y0,
            .B = x0 - x1,
            .C = y0 * x1 - x0 * y1,
        };
    }

    // Evaluate the position of p against the oriented edge a -> b
    inline fn edge(a: @Vector(2, i32), b: @Vector(2, i32), p: @Vector(2, i32)) i32 {
        return (p[0] - a[0]) * (b[1] - a[1]) - (p[1] - a[1]) * (b[0] - a[0]);
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

    pub inline fn render_triangle(self: *Triangle, fb: *ctx.Framebuffer) void {
        var a = self.v0;
        var b = self.v1;
        var c = self.v2;

        const tri_area = edge(a, b, c);

        // WARN: Trying without this
        // If edge func is neg, then the triangle is oriented clockwise.
        // Swap any two vertices to reorient the triangle counter-clockwise.
        // if (tri_area < 0) {
        //     const tmp = b;
        //     b = c;
        //     c = tmp;
        //     tri_area = -tri_area;
        // }

        const inv_tri_area_f32 = 1 / @as(f32, @floatFromInt(tri_area));

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
        const v0_c_f32 = @as(@Vector(3, f32), @floatFromInt(xrgb_to_vec3(self.v0_col)));
        const v1_c_f32 = @as(@Vector(3, f32), @floatFromInt(xrgb_to_vec3(self.v1_col)));
        const v2_c_f32 = @as(@Vector(3, f32), @floatFromInt(xrgb_to_vec3(self.v2_col)));

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
                if ((w0 >= 0 and w1 >= 0 and w2 >= 0) or (w0 < 0 and w1 < 0 and w2 < 0)) {
                    const beta = @as(f32, @floatFromInt(w1)) * inv_tri_area_f32;
                    const gamma = @as(f32, @floatFromInt(w2)) * inv_tri_area_f32;
                    const alpha = 1 - beta - gamma;

                    const rgb: @Vector(3, f32) = v0_c_f32 * @as(@Vector(3, f32), @splat(alpha)) +
                        v1_c_f32 * @as(@Vector(3, f32), @splat(beta)) +
                        v2_c_f32 * @as(@Vector(3, f32), @splat(gamma));

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
