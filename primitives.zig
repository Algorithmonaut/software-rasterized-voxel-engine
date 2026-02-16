const std = @import("std");
const ctx = @import("context.zig");

pub const Vertex2D = struct {
    pos: @Vector(2, i32),
    col: u32,
};

pub const Triangle = struct {
    v0: @Vector(2, i32),
    v1: @Vector(2, i32),
    v2: @Vector(2, i32),

    const Edge = struct {
        // Edge function can be refactored E(x,y) = Ax + By + C with A B C constants
        A: i32,
        B: i32,
        C: i32, // WARN: Change to i64 if overflow

        // Evaluate the point (x, y) against the edge
        inline fn eval(self: Edge, x: i32, y: i32) i32 {
            return self.A * x + self.B * y + self.C; // WARN: Cast to i64 if overflow
        }

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
    };

    // Evaluate the position of p against the oriented edge a -> b
    inline fn edge(
        ax: i32,
        ay: i32,
        bx: i32,
        by: i32,
        px: i32,
        py: i32,
    ) i32 {
        return (px - ax) * (by - ay) - (py - ay) * (bx - ax);
    }

    pub inline fn render_triangle(self: *Triangle, fb: *ctx.Framebuffer) void {
        var ax = self.v0[0];
        var ay = self.v0[1];
        var bx = self.v1[0];
        var by = self.v1[1];
        const cx = self.v2[0];
        const cy = self.v2[1];

        // If edge func is neg, then the triangle is oriented clockwise.
        // Swap any two vertices to reorient the triangle counter-clockwise.
        if (edge(ax, ay, bx, by, cx, cy) < 0) {
            const tmp_x = ax;
            const tmp_y = ay;
            ax = bx;
            ay = by;
            bx = tmp_x;
            by = tmp_y;
        }

        // Compute the bounding box of the triangle
        const x_min = @min(ax, bx, cx);
        const x_max = @max(ax, bx, cx);
        const y_min = @min(ay, by, cy);
        const y_max = @max(ay, by, cy);

        // NOTE: Compute the edge deltas for incremental stepping

        // For edge v0 -> v1
        const e0_step_x = by - ay;
        const e0_step_y = ax - bx;

        // For edge v1 -> v2
        const e1_step_x = cy - by;
        const e1_step_y = bx - cx;

        // For edge v2 -> v0
        const e2_step_x = ay - cy;
        const e2_step_y = cx - ax;

        // Evaluate edges at top-left of bbox
        var w0_row = edge(ax, ay, bx, by, x_min, y_min);
        var w1_row = edge(bx, by, cx, cy, x_min, y_min);
        var w2_row = edge(cx, cy, ax, ay, x_min, y_min);

        // NOTE: Incremental stepping

        var y: i32 = y_min;
        while (y <= y_max) : (y += 1) {
            var w0: i32 = w0_row;
            var w1: i32 = w1_row;
            var w2: i32 = w2_row;

            var x: i32 = x_min;
            while (x <= x_max) : (x += 1) {
                if (w0 >= 0 and w1 >= 0 and w2 >= 0) {
                    fb.set_pixel(x, y, 0xFFFFFFFF);
                }

                // Step right
                w0 += e0_step_x;
                w1 += e1_step_x;
                w2 += e2_step_x;
            }

            // Step down
            w0_row += e0_step_y;
            w1_row += e1_step_y;
            w2_row += e2_step_y;
        }
    }
};
