const std = @import("std");

const FogMode = enum { none, linear, exp, exp2 };

pub const Fog = struct {
    enabled: bool = true,
    mode: FogMode = .linear,

    // Linear fog
    start: f32 = 300,
    end: f32 = 400,

    // exp/exp2 fog
    density: f32 = 0.004,

    color: u32 = 0xFF000000,
    // color: u32 = 0xFFFFFFFF,

    pub inline fn fogFactor(self: Fog, c: f32) f32 {
        if (!self.enabled or self.mode == .none) return 1.0;

        const f = switch (self.mode) {
            .none => 1,
            .linear => (self.end - c) / (self.end - self.start),
            .exp => std.math.exp(-self.density * c),
            .exp2 => blk: {
                const d = self.density * c;
                break :blk std.math.exp(-(d * d));
            },
        };

        return std.math.clamp(f, 0.0, 1.0);
    }

    pub inline fn blendFogARGB8(self: Fog, src: u32, f: f32) u32 {
        const fog_color = self.color;
        const invf = 1.0 - f;

        const sa: u32 = (src >> 24) & 0xFF;
        const sr: u32 = (src >> 16) & 0xFF;
        const sg: u32 = (src >> 8) & 0xFF;
        const sb: u32 = src & 0xFF;

        const fr: u32 = (fog_color >> 16) & 0xFF;
        const fg: u32 = (fog_color >> 8) & 0xFF;
        const fb: u32 = fog_color & 0xFF;

        const r: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(sr)) * f +
            @as(f32, @floatFromInt(fr)) * invf));
        const g: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(sg)) * f +
            @as(f32, @floatFromInt(fg)) * invf));
        const b: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(sb)) * f +
            @as(f32, @floatFromInt(fb)) * invf));

        return (sa << 24) | (r << 16) | (g << 8) | b;
    }
};
