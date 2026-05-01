const types = @import("types.zig");

const WorldCoord = types.WorldCoord;

pub const EngineConfig = struct {
    pub const CameraConfig = struct {
        fov: f32,
        view_distance: f32,
        near: f32,
        sensitivity: f32,
    };

    pub const PlayerConfig = struct {
        half_size: WorldCoord,
        initial_position: WorldCoord,

        ground_accel: f32,
        air_accel: f32,
        ground_decel: f32,
        air_decel: f32,

        gravity: f32,
        jump_speed: f32,

        speed: f32,
    };

    pub const FramebufferConfig = struct {
        width: usize,
        height: usize,
        scale: usize,
        tile_dimensions: usize, // should be 2^n
    };

    pub const AtlasConfig = struct {
        width: usize,
        height: usize,
        tex_w: usize,
        tex_h: usize,
    };

    pub const DebugConfig = struct {
        show_fps: bool,
        show_tex_atlas: bool,
        show_occupied_tiles: bool,
    };

    pub const WorldConfig = struct {
        // Typical parameters:
        // octaves = 4..6
        // lacunarity = 2.0
        // gain = 0.5

        seed: u32,
        /// Number of noise layouts combined together
        octaves: u32,
        /// How much the frequency increase between each octaves
        lacunarity: f32,
        /// Multiplier for how much each octave contributes to the final result
        gain: f32,
        /// Smaller = smoother terrain
        scale: f32,

        mountain_seed: u32,
        mountain_octaves: u32,
        mountain_lacunarity: f32,
        mountain_gain: f32,
        mountain_scale: f32,

        /// Inclusive
        min_world_y: i32,
        /// Exclusive
        max_world_y: i32,

        bootstrap_radius_chunk: i32,
        render_radius_chunks: i32,
        collision_radius_chunks: i32,

        gen_budget_per_tick: u32,
        mesh_budget_per_tick: u32,
    };

    camera_config: CameraConfig,
    player_config: PlayerConfig,
    framebuffer_config: FramebufferConfig,
    atlas_config: AtlasConfig,
    world_config: WorldConfig,
    debug_config: DebugConfig,
};
