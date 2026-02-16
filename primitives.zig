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

        var tri_area = edge(a, b, c);

        // If edge func is neg, then the triangle is oriented clockwise.
        // Swap any two vertices to reorient the triangle counter-clockwise.
        if (tri_area < 0) {
            const tmp = b;
            b = c;
            c = tmp;
            tri_area = -tri_area;
        }

        // Compute the bbox and clip it to the viewport
        var x_min_i: i32 = @min(a[0], b[0], c[0]);
        var x_max_i: i32 = @max(a[0], b[0], c[0]);
        var y_min_i: i32 = @min(a[1], b[1], c[1]);
        var y_max_i: i32 = @max(a[1], b[1], c[1]);

        const w: i32 = @intCast(fb.width);
        const h: i32 = @intCast(fb.height);

        // Reject if the triangle is out of the viewport
        if (x_max_i < 0 or y_max_i < 0 or x_min_i > w or y_min_i > h) return;

        // Clamp the bounding box to the viewport
        x_min_i = std.math.clamp(x_min_i, 0, w - 1);
        x_max_i = std.math.clamp(x_max_i, 0, w - 1);
        y_min_i = std.math.clamp(y_min_i, 0, h - 1);
        y_max_i = std.math.clamp(y_max_i, 0, h - 1);

        // NOTE: Compute the edges
        const e0 = make_edge(a, b);
        const e1 = make_edge(b, c);
        const e2 = make_edge(c, a);

        // P: Decompose vertex colors into channels
        const v0_color_channel_f32 = @as(@Vector(3, f32), @floatFromInt(xrgb_to_vec3(self.v0_col)));
        const v1_color_channel_f32 = @as(@Vector(3, f32), @floatFromInt(xrgb_to_vec3(self.v1_col)));
        const v2_color_channel_f32 = @as(@Vector(3, f32), @floatFromInt(xrgb_to_vec3(self.v2_col)));

        // Evaluate edges at top-left of bbox
        const start_w0 = e0.eval(x_min_i, y_min_i);
        const start_w1 = e1.eval(x_min_i, y_min_i);
        const start_w2 = e2.eval(x_min_i, y_min_i);

        // Incremental stepping
        const step_x0: i32 = e0.A; // move right: +A
        const step_x1: i32 = e1.A;
        const step_x2: i32 = e2.A;

        const step_y0: i32 = e0.B; // move down: +B
        const step_y1: i32 = e1.B;
        const step_y2: i32 = e2.B;

        var w0_row = start_w0;
        var w1_row = start_w1;
        var w2_row = start_w2;

        // Convert bbox to usize for incremental stepping
        const x_min: usize = @intCast(x_min_i);
        const x_max: usize = @intCast(x_max_i);
        const y_min: usize = @intCast(y_min_i);
        const y_max: usize = @intCast(y_max_i);

        // NOTE: Incremental stepping

        // Prefer using usize directly

        var y: usize = y_min;
        while (y <= y_max) : (y += 1) {
            const line = fb.get_scanline(y);

            var w0: i32 = w0_row;
            var w1: i32 = w1_row;
            var w2: i32 = w2_row;

            var x: usize = x_min;
            while (x <= x_max) : (x += 1) {
                // If the point is inside the triangle
                if (w0 >= 0 and w1 >= 0 and w2 >= 0) {
                    const beta = @as(f32, @floatFromInt(w1)) / @as(f32, @floatFromInt(tri_area));
                    const gamma = @as(f32, @floatFromInt(w2)) / @as(f32, @floatFromInt(tri_area));
                    const alpha = 1 - beta - gamma;

                    const rgb: @Vector(3, f32) = v0_color_channel_f32 * @as(@Vector(3, f32), @splat(alpha)) + v1_color_channel_f32 * @as(@Vector(3, f32), @splat(beta)) + v2_color_channel_f32 * @as(@Vector(3, f32), @splat(gamma));
                    const rgb_u8: @Vector(3, u8) = @intFromFloat(rgb);

                    const out_color: u32 = vec3_to_xrgb(rgb_u8);

                    line[x] = out_color;
                }

                // Step right
                w0 += step_x0;
                w1 += step_x1;
                w2 += step_x2;
            }

            // Step down
            w0_row += step_y0;
            w1_row += step_y1;
            w2_row += step_y2;
        }
    }
};
