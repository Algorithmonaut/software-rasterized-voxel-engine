const t = @import("../math/types.zig");

pub const EngineConfig = struct {
    pub const CameraConfig = struct {
        fov: t.Float,
        from: t.Vec3f,
        to: t.Vec3f,
        view_distance: t.Float,
        speed: t.Float,
    };

    pub const FramebufferConfig = struct {
        width: usize,
        height: usize,
        scale: usize,
        tile_dimensions: usize,
    };

    camera_config: CameraConfig,
    framebuffer_config: FramebufferConfig,
};
