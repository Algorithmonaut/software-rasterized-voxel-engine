// NOTE: Refactored: YES

const Framebuffer = @import("Framebuffer.zig").Framebuffer;

/// Holds per-frame values and allocations
pub const FrameContext = struct {
    dt: f32,
    framebuffer: Framebuffer,
};
