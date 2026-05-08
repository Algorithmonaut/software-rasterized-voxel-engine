const std = @import("std");
const sdl = @import("sdl");

const Framebuffer = @import("../Framebuffer.zig").Framebuffer;
const FramebufferConfig = @import("../EngineConfig.zig").EngineConfig.FramebufferConfig;

pub const SdlGraphics = struct {
    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    texture: *sdl.SDL_Texture,

    width: c_int,
    height: c_int,
    scale: c_int,

    pub fn init(conf: FramebufferConfig) !SdlGraphics {
        const width: c_int = @intCast(conf.width);
        const height: c_int = @intCast(conf.height);
        const scale: c_int = @intCast(conf.scale);

        if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_EVENTS) != 0) {
            std.debug.print("SDL_Init failed: {s}\n", .{sdl.SDL_GetError()});
            return error.SDLInitFailed;
        }

        const win = sdl.SDL_CreateWindow(
            "Software Rasterizer",
            sdl.SDL_WINDOWPOS_CENTERED,
            sdl.SDL_WINDOWPOS_CENTERED,
            width * scale,
            height * scale,
            0,
        ) orelse {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{sdl.SDL_GetError()});
            return error.SDLWindowFailed;
        };

        const renderer = sdl.SDL_CreateRenderer(win, -1, sdl.SDL_RENDERER_ACCELERATED) orelse {
            std.debug.print("SDL_CreateRenderer failed: {s}\n", .{sdl.SDL_GetError()});
            return error.SDLRendererFailed;
        };

        _ = sdl.SDL_SetRelativeMouseMode(sdl.SDL_TRUE); // locks cursor + gives relative deltas

        const tex = sdl.SDL_CreateTexture(
            renderer,
            sdl.SDL_PIXELFORMAT_ARGB8888,
            sdl.SDL_TEXTUREACCESS_STREAMING, // the texture's pixels will be frequently updated
            width,
            height,
        ) orelse {
            std.debug.print("SDL_CreateTexture failed: {s}\n", .{sdl.SDL_GetError()});
            return error.SDLTextureFailed;
        };

        return .{
            .window = win,
            .renderer = renderer,
            .texture = tex,
            .width = width,
            .height = height,
            .scale = scale,
        };
    }

    pub fn deinit(self: *SdlGraphics) void {
        _ = self;
    }

    pub fn begin_frame(self: *SdlGraphics) !Framebuffer {
        var pixels: ?*anyopaque = null;
        var pitch_c: c_int = 0;

        if (sdl.SDL_LockTexture(self.texture, null, &pixels, &pitch_c) != 0) {
            return error.SDLLockFailed;
        }

        const pitch: usize = @intCast(pitch_c);
        const base: [*]u8 = @ptrCast(pixels.?);

        return .{
            .base = base,
            .pitch = pitch,
            .width = @intCast(self.width),
            .height = @intCast(self.height),
        }; // Returns a framebuffer object
    }

    pub fn end_frame(self: *SdlGraphics) void {
        sdl.SDL_UnlockTexture(self.texture);
    }

    pub fn present(self: *SdlGraphics) void {
        var dst: sdl.SDL_Rect = .{
            .x = 0,
            .y = 0,
            .w = @intCast(@as(c_int, @intCast(self.width)) * self.scale),
            .h = @intCast(@as(c_int, @intCast(self.height)) * self.scale),
        };

        _ = sdl.SDL_RenderCopy(self.renderer, self.texture, null, &dst);
        sdl.SDL_RenderPresent(self.renderer);
    }
};
