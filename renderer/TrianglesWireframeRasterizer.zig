// I use DDA line rasterization, I don't want to overcomplicate things with
// Bresenham or Wu.

// const RasterTriangle = @import("../triangle.zig").RasterTriangle;
// const Framebuffer = @import("../Framebuffer.zig").Framebuffer;
//
// const types = @import("../math/types.zig");
// const Vec2fx = types.Vec2fx;
// const SUBPIXEL_BITS = types.SUBPIXEL_BITS;
// const SUBPIXEL_MASK = (1 << SUBPIXEL_BITS) - 1;
//
// fn drawLineXMajor(
//     x0: f32,
//     y0: f32,
//     z0: f32,
//     x1: f32,
//     y1: f32,
//     z1: f32,
//     fb: Framebuffer,
// ) void {
//     var ax = x0;
//     var ay = y0;
//     var az = z0;
//     var ax = x0;
//     var ay = y0;
//     var az = z0;
// }
//
// inline fn renderLine(v0: Vec2fx, v1: Vec2fx, fb: Framebuffer) void {
//     const dx = v1[0] - v0[0];
//     const dy = v1[1] - v0[1];
//
//     if (@abs(dx) >= @abs(dy))
//         drawLineXMajor()
//     else
//         drawLineYMajor();
// }
//
// fn renderTriangleWireframeInFb(
//     triangle: *const RasterTriangle,
//     fb: Framebuffer,
// ) void {}
