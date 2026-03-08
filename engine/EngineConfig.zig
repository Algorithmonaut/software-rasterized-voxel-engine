const t = @import("../math/types.zig");

pub const EngineConfig = struct {
    pub const CameraConfig = struct {
        fov: t.Float,
        from: t.Vec3f,
        to: t.Vec3f,
        view_distance: t.Float,
        speed: t.Float,
        sensivity: t.Float,
    };

    pub const FramebufferConfig = struct {
        width: usize,
        height: usize,
        scale: usize,
        tile_dimensions: usize,
    };

    pub const AtlasConfig = struct {
        width: usize,
        height: usize,
        tex_w: usize,
        tex_h: usize,
        pixel_type: type,
        channels_rgb: usize,
    };

    camera_config: CameraConfig,
    framebuffer_config: FramebufferConfig,
    atlas_config: AtlasConfig,
};
