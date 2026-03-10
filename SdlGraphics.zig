// NOTE: Refactored: YES

const FramebufferConfig = @import("EngineConfig.zig").EngineConfig.FramebufferConfig;

const std = @import("std");
const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL2/SDL.h");
});
const Framebuffer = @import("Framebuffer.zig").Framebuffer;
const Float = @import("math/types.zig").Float;

pub const SdlGraphics = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    texture: *c.SDL_Texture,

    width: c_int,
    height: c_int,
    scale: c_int,

    pub fn init(conf: FramebufferConfig) !SdlGraphics {
        const width: c_int = @intCast(conf.width);
        const height: c_int = @intCast(conf.height);
        const scale: c_int = @intCast(conf.scale);

        if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS) != 0) {
            std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLInitFailed;
        }

        const win = c.SDL_CreateWindow(
            "Software Rasterizer",
            c.SDL_WINDOWPOS_CENTERED,
            c.SDL_WINDOWPOS_CENTERED,
            width * scale,
            height * scale,
            0,
        ) orelse {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLWindowFailed;
        };

        const renderer = c.SDL_CreateRenderer(win, -1, c.SDL_RENDERER_ACCELERATED) orelse {
            std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLRendererFailed;
        };

        _ = c.SDL_SetRelativeMouseMode(c.SDL_TRUE); // locks cursor + gives relative deltas

        const tex = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_ARGB8888,
            c.SDL_TEXTUREACCESS_STREAMING, // the texture's pixels will be frequently updated
            width,
            height,
        ) orelse {
            std.debug.print("SDL_CreateTexture failed: {s}\n", .{c.SDL_GetError()});
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

        if (c.SDL_LockTexture(self.texture, null, &pixels, &pitch_c) != 0) {
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
        c.SDL_UnlockTexture(self.texture);
    }

    pub fn present(self: *SdlGraphics) void {
        var dst: c.SDL_Rect = .{
            .x = 0,
            .y = 0,
            .w = @intCast(@as(c_int, @intCast(self.width)) * self.scale),
            .h = @intCast(@as(c_int, @intCast(self.height)) * self.scale),
        };

        _ = c.SDL_RenderCopy(self.renderer, self.texture, null, &dst);
        c.SDL_RenderPresent(self.renderer);
    }
};
