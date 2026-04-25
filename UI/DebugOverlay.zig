const std = @import("std");
const types = @import("../math/types.zig");
const vec = @import("../math/vector.zig");

const F3 = types.Vec3f;
const Text = @import("Text.zig").Text;
const Mat4f = @import("../math/matrix.zig").Mat4f;
const Framebuffer = @import("../Framebuffer.zig").Framebuffer;

pub const DebugOverlay = struct {
    const RenderMode = enum { NATIVE, WIREFRAME, Z_BUF, DEPTH };

    const header_color: u32 = 0xFFFABD2F;
    const text_color: u32 = 0xFFFFFFFF;
    const comment_color: u32 = 0xFF928374;

    const margin_x: usize = 10;
    const margin_y: usize = 10;

    clear_black: bool = false,
    enabled: bool = true,

    guizmo_render_scale: f32 = 50,

    chunk_loaded: usize = 0,
    chunk_active: usize = 0,
    chunk_visible: usize = 0,
    chunk_generating: usize = 0,
    chunk_meshing: usize = 0,

    visible_chunk_triangles: usize = 0,
    triangles_after_bucket_cull: usize = 0,
    triangles_after_clipping: usize = 0,

    player_pos: F3 = .{ 0, 0, 0 },
    player_vel: F3 = .{ 0, 0, 0 },
    player_grounded: bool = false,
    player_noclip: bool = false,

    render_mode: RenderMode = .NATIVE,

    fps: f64 = 0,

    inline fn printRawLine(
        text: *Text,
        fb: *Framebuffer,
        x: usize,
        y: usize,
        line: []const u8,
        color: u32,
        padding: usize,
    ) usize {
        text.printText(x + padding * text.glyph_width, y, line, color, fb);
        return text.glyph_height;
    }

    inline fn printSectionHeader(
        text: *Text,
        fb: *Framebuffer,
        x: usize,
        y: usize,
        label: []const u8,
    ) usize {
        return printRawLine(text, fb, x, y, label, header_color, 0);
    }

    inline fn printFmtLine(
        text: *Text,
        fb: *Framebuffer,
        x: usize,
        y: usize,
        buf: []u8,
        comptime fmt: []const u8,
        args: anytype,
    ) usize {
        const line = std.fmt.bufPrint(buf, fmt, args) catch unreachable;
        return printRawLine(text, fb, x, y, line, text_color, 3);
    }

    inline fn printFmtComment(
        text: *Text,
        fb: *Framebuffer,
        x: usize,
        y: usize,
        buf: []u8,
        comptime fmt: []const u8,
        args: anytype,
    ) usize {
        const line = std.fmt.bufPrint(buf, fmt, args) catch unreachable;
        return printRawLine(text, fb, x, y, line, comment_color, 6);
    }

    inline fn addBlankLine(text: *Text) usize {
        return text.glyph_height;
    }

    inline fn boolStr(v: bool) []const u8 {
        return if (v) "TRUE" else "FALSE";
    }

    inline fn eliminatedPerc(before: usize, after: usize) f32 {
        if (before == 0) return 0;
        const before_f: f32 = @floatFromInt(before);
        return (before_f - @as(f32, @floatFromInt(after))) / before_f * 100;
    }

    inline fn remainingPerc(before: usize, after: usize) f32 {
        if (before == 0) return 0;
        return @as(f32, @floatFromInt(after)) / @as(f32, @floatFromInt(before)) * 100;
    }

    fn fmtUsizeStep(buf: []u8, value: usize) []const u8 {
        var n = value;
        var j = buf.len;
        var group: usize = 0;

        while (true) {
            if (group == 3) {
                j -= 1;
                buf[j] = ',';
                group = 0;
            }
            j -= 1;
            buf[j] = @as(u8, '0') + @as(u8, @intCast(n % 10));
            n /= 10;
            group += 1;
            if (n == 0) break;
        }

        return buf[j..];
    }

    pub fn renderGizmo(
        self: *DebugOverlay,
        fb: *Framebuffer,
        camera_position: F3,
        camera_target: F3,
    ) void {
        const ref_up = F3{ 0, 1, 0 };

        const forward = vec.normalize(camera_target - camera_position);
        const right = vec.normalize(vec.cross_product(forward, ref_up));
        const up = vec.normalize(vec.cross_product(right, forward));

        const pos_x: i32 = 360;
        const pos_y: i32 = 400;
        const scale = self.guizmo_render_scale;

        const PointDepth = struct {
            p: [2]i32,
            z: f32,
            color: u32,
        };

        var pts = [_]PointDepth{
            // World +X
            .{
                .p = .{
                    pos_x + @as(i32, @intFromFloat(right[0] * scale)),
                    pos_y - @as(i32, @intFromFloat(up[0] * scale)),
                },
                .z = -forward[0],
                .color = 0xFFFF0000,
            },
            // World +Y
            .{
                .p = .{
                    pos_x + @as(i32, @intFromFloat(right[1] * scale)),
                    pos_y - @as(i32, @intFromFloat(up[1] * scale)),
                },
                .z = -forward[1],
                .color = 0xFF00FF00,
            },
            // World +Z
            .{
                .p = .{
                    pos_x + @as(i32, @intFromFloat(right[2] * scale)),
                    pos_y - @as(i32, @intFromFloat(up[2] * scale)),
                },
                .z = -forward[2],
                .color = 0xFF5050FF,
            },
        };

        // Ascending: farthest first, closest last
        if (pts[0].z > pts[1].z)
            std.mem.swap(PointDepth, &pts[0], &pts[1]);
        if (pts[1].z > pts[2].z)
            std.mem.swap(PointDepth, &pts[1], &pts[2]);
        if (pts[0].z > pts[1].z)
            std.mem.swap(PointDepth, &pts[0], &pts[1]);

        inline for (pts) |pt| {
            fb.drawLineBold(pos_x, pos_y, pt.p[0], pt.p[1], 3, pt.color);
        }
    }

    pub fn render(self: *DebugOverlay, text: *Text, fb: *Framebuffer) !void {
        if (!self.enabled) return;

        if (self.clear_black) {
            for (0..540) |i|
                @memset(fb.base[i * fb.width * 4 .. i * fb.width * 4 + 440 * 4], 0);
        }

        var y: usize = margin_y;

        var buf: [128]u8 = undefined;
        var nbuf: [32]u8 = undefined;

        y += printSectionHeader(text, fb, margin_x, y, " CHUNKS: ");
        y += printFmtLine(text, fb, margin_x, y, &buf, " LOADED: {s} ", .{fmtUsizeStep(&nbuf, self.chunk_loaded)});
        y += printFmtLine(text, fb, margin_x, y, &buf, " ACTIVE: {s} ", .{fmtUsizeStep(&nbuf, self.chunk_active)});
        y += printFmtLine(text, fb, margin_x, y, &buf, " VISIBLE: {s} ", .{fmtUsizeStep(&nbuf, self.chunk_visible)});
        y += printFmtLine(text, fb, margin_x, y, &buf, " GENERATING: {s} ", .{fmtUsizeStep(&nbuf, self.chunk_generating)});
        y += printFmtLine(text, fb, margin_x, y, &buf, " MESHING: {s} ", .{fmtUsizeStep(&nbuf, self.chunk_meshing)});
        y += addBlankLine(text);

        const initial = self.visible_chunk_triangles;
        const bucket_culled = self.triangles_after_bucket_cull;
        const clipped = self.triangles_after_clipping;
        y += printSectionHeader(text, fb, margin_x, y, " TRIANGLES: ");
        y += printFmtLine(text, fb, margin_x, y, &buf, " VISIBLE CHUNK TRIANGLES: {s} ", .{fmtUsizeStep(&nbuf, initial)});
        y += printFmtLine(text, fb, margin_x, y, &buf, " AFTER BUCKET CULL: {s} ", .{fmtUsizeStep(&nbuf, bucket_culled)});
        y += printFmtComment(text, fb, margin_x, y, &buf, " remaining: {d:.2}% ", .{remainingPerc(initial, bucket_culled)});
        y += printFmtComment(text, fb, margin_x, y, &buf, " eliminated: {d:.2}% ", .{eliminatedPerc(initial, bucket_culled)});
        y += printFmtLine(text, fb, margin_x, y, &buf, " AFTER CLIPPING: {s} ", .{fmtUsizeStep(&nbuf, clipped)});
        y += printFmtComment(text, fb, margin_x, y, &buf, " remaining: {d:.2}% ", .{remainingPerc(initial, clipped)});
        y += printFmtComment(text, fb, margin_x, y, &buf, " eliminated: {d:.2}% ", .{eliminatedPerc(initial, clipped)});
        y += printFmtComment(text, fb, margin_x, y, &buf, " eliminated since bucket cull: {d:.2}% ", .{eliminatedPerc(bucket_culled, clipped)});
        y += addBlankLine(text);

        y += printSectionHeader(text, fb, margin_x, y, " PLAYER: ");
        y += printFmtLine(text, fb, margin_x, y, &buf, " POSITION: {d:.2} {d:.2} {d:.2} ", .{ self.player_pos[0], self.player_pos[1], self.player_pos[2] });
        y += printFmtLine(text, fb, margin_x, y, &buf, " VELOCITY: {d:.2} {d:.2} {d:.2} ", .{ self.player_vel[0], self.player_vel[1], self.player_vel[2] });
        y += printFmtLine(text, fb, margin_x, y, &buf, " GROUNDED: {s} ", .{boolStr(self.player_grounded)});
        y += printFmtLine(text, fb, margin_x, y, &buf, " NO CLIP: {s} ", .{boolStr(self.player_noclip)});

        y += addBlankLine(text);

        y += addBlankLine(text);
        y += addBlankLine(text);
        y += addBlankLine(text);

        y += printFmtLine(text, fb, margin_x, y, &buf, " | RENDER MODE: {s} ", .{@tagName(self.render_mode)});
        y += printFmtLine(text, fb, margin_x, y, &buf, " | FPS: {d:.1} ", .{self.fps});
    }

    pub inline fn frameReset(self: *DebugOverlay) void {
        self.visible_chunk_triangles = 0;
        self.triangles_after_bucket_cull = 0;
        self.triangles_after_clipping = 0;
    }
};
