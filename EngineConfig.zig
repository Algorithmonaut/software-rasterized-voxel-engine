const WorldCoord = @import("math/types.zig").WorldCoord;

pub const EngineConfig = struct {
    pub const CameraConfig = struct {
        fov: f32,
        from: WorldCoord,
        to: WorldCoord,
        view_distance: f32,
        speed: f32,
        sensivity: f32,
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

    pub const WorldConfig = struct {
        chunk_size: usize,
    };

    camera_config: CameraConfig,
    framebuffer_config: FramebufferConfig,
    atlas_config: AtlasConfig,
    world_config: WorldConfig,
};
