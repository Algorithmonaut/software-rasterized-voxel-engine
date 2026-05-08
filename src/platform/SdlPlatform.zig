const std = @import("std");
const sdl = @import("sdl");
const main = @import("../main.zig");
const vec = @import("../math/vector.zig");
const types = @import("../types.zig");

const SdlGraphics = @import("SdlGraphics.zig").SdlGraphics;
const Player = @import("../game/Player.zig").Player;

const F3 = types.F3;

pub const SdlPlatform = struct {
    freq: u64, // tick counter
    last_frame: u64, // ticks per second
    last_fps: u64,
    now: u64,
    frames: u64, // frame counter
    running: bool,
    drop_next_mouse_delta: bool,

    mouse_capture: bool,
    ev: sdl.SDL_Event,

    prev_mouse_buttons: u32 = 0,

    pub fn init() SdlPlatform {
        const freq = sdl.SDL_GetPerformanceFrequency();
        const now = sdl.SDL_GetPerformanceCounter();

        return .{
            .freq = freq,
            .last_frame = now,
            .last_fps = now,
            .now = now,
            .frames = 0,
            .running = true,
            .ev = undefined,
            .mouse_capture = true,
            .drop_next_mouse_delta = false,
        };
    }

    pub fn deinit(self: *SdlPlatform) void {
        _ = self;
    }

    /// Returns dt in seconds
    pub fn begin_frame(self: *SdlPlatform) f32 {
        const now: u64 = sdl.SDL_GetPerformanceCounter();
        const delta_counts: u64 = now - self.last_frame;
        self.last_frame = now;
        return @as(f32, @floatFromInt(delta_counts)) / @as(f32, @floatFromInt(self.freq));
    }

    pub fn fps_counter_update(self: *SdlPlatform) void {
        self.frames += 1;

        const now: u64 = sdl.SDL_GetPerformanceCounter();
        const elapsed_counts: u64 = now - self.last_fps;

        if (elapsed_counts >= self.freq) { // ~1 second
            const elapsed_s: f64 =
                @as(f64, @floatFromInt(elapsed_counts)) / @as(f64, @floatFromInt(self.freq));

            const fps: f64 = @as(f64, @floatFromInt(self.frames)) / elapsed_s;
            main.debug_overlay.fps = fps;

            self.frames = 0;
            self.last_fps = now;
        }
    }

    fn pressedThisFrame(
        keys: [*c]const u8,
        prev_keys: *const [sdl.SDL_NUM_SCANCODES]u8,
        scancode: usize,
    ) bool {
        return keys[scancode] != 0 and prev_keys[scancode] == 0;
    }

    // This should return the struct rather than getting Player
    pub fn processInputs(
        self: *SdlPlatform,
        dt: f32,
        player: *Player,
    ) void {
        while (sdl.SDL_PollEvent(&self.ev) != 0) {
            switch (self.ev.type) {
                sdl.SDL_QUIT => self.running = false,
                sdl.SDL_KEYDOWN => {
                    const key = self.ev.key.keysym.sym;

                    if (self.ev.key.repeat == 0 and key == sdl.SDLK_TAB) {
                        self.mouse_capture = !self.mouse_capture;
                        self.drop_next_mouse_delta = !self.drop_next_mouse_delta;

                        _ = sdl.SDL_SetRelativeMouseMode(if (self.mouse_capture) sdl.SDL_TRUE else sdl.SDL_FALSE);

                        if (self.mouse_capture) self.drop_next_mouse_delta = true;
                    }
                },

                else => {},
            }
        }

        {
            var dx: i32 = 0;
            var dy: i32 = 0;

            if (self.mouse_capture) {
                _ = sdl.SDL_GetRelativeMouseState(&dx, &dy);

                if (self.drop_next_mouse_delta) {
                    dx = 0;
                    dy = 0;
                    self.drop_next_mouse_delta = false;
                }
            }

            const mouse_buttons: u32 = sdl.SDL_GetMouseState(null, null);
            const keys = sdl.SDL_GetKeyboardState(null);

            const left_down_now = (mouse_buttons & sdl.SDL_BUTTON_LMASK) != 0;
            const left_down_before = (self.prev_mouse_buttons & sdl.SDL_BUTTON_LMASK) != 0;

            const right_down_now = (mouse_buttons & sdl.SDL_BUTTON_RMASK) != 0;
            const right_down_before = (self.prev_mouse_buttons & sdl.SDL_BUTTON_RMASK) != 0;

            player.frame_inputs = .{
                .forward = keys[sdl.SDL_SCANCODE_W] != 0,
                .back = keys[sdl.SDL_SCANCODE_S] != 0,
                .right = keys[sdl.SDL_SCANCODE_D] != 0,
                .left = keys[sdl.SDL_SCANCODE_A] != 0,
                .up = keys[sdl.SDL_SCANCODE_SPACE] != 0,
                .down = keys[sdl.SDL_SCANCODE_E] != 0,

                .mouse_dx = dx,
                .mouse_dy = dy,

                .place_block = right_down_now and !right_down_before,
                .break_block = left_down_now and !left_down_before,

                .dt = dt,
            };

            self.prev_mouse_buttons = mouse_buttons;
        }
    }
};
