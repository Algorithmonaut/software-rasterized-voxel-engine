const Framebuffer = @import("Framebuffer.zig").Framebuffer;

pub const FrameContext = struct {
    dt: f32,
    framebuffer: Framebuffer,
};
