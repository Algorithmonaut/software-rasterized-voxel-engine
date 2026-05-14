const std = @import("std");

pub const RasterizerTimings = struct {
    clear_ns: u64 = 0,
    count_ns: u64 = 0,
    prefix_ns: u64 = 0,
    ensure_refs_ns: u64 = 0,
    scatter_ns: u64 = 0,
    tiles_ns: u64 = 0,

    pub fn total(self: RasterizerTimings) u64 {
        return self.clear_ns +
            self.count_ns +
            self.prefix_ns +
            self.ensure_refs_ns +
            self.scatter_ns +
            self.tiles_ns;
    }
};

pub const FrameTimings = struct {
    frame_ns: u64 = 0,

    drain_chunks_ns: u64 = 0,
    begin_frame_ns: u64 = 0,
    input_ns: u64 = 0,
    player_update_ns: u64 = 0,
    camera_ns: u64 = 0,
    sky_ns: u64 = 0,
    update_chunks_ns: u64 = 0,
    visible_chunks_ns: u64 = 0,
    primitive_build_ns: u64 = 0,
    debug_overlay_ns: u64 = 0,
    rasterizer: RasterizerTimings = .{},
    overlay_render_ns: u64 = 0,
    end_frame_ns: u64 = 0,

    visible_chunks: usize = 0,
    primitives: usize = 0,
    vertices: usize = 0,
    tile_refs: usize = 0,

    pub fn zero(self: *FrameTimings) void {
        self.* = .{};
    }
};

pub const RollingProfiler = struct {
    const window = 120;

    accum: FrameTimings = .{},
    samples: u32 = 0,

    pub fn push(self: *RollingProfiler, t: FrameTimings) void {
        self.accum.frame_ns += t.frame_ns;

        self.accum.drain_chunks_ns += t.drain_chunks_ns;
        self.accum.begin_frame_ns += t.begin_frame_ns;
        self.accum.input_ns += t.input_ns;
        self.accum.player_update_ns += t.player_update_ns;
        self.accum.camera_ns += t.camera_ns;
        self.accum.sky_ns += t.sky_ns;
        self.accum.update_chunks_ns += t.update_chunks_ns;
        self.accum.visible_chunks_ns += t.visible_chunks_ns;
        self.accum.primitive_build_ns += t.primitive_build_ns;
        self.accum.debug_overlay_ns += t.debug_overlay_ns;
        self.accum.overlay_render_ns += t.overlay_render_ns;
        self.accum.end_frame_ns += t.end_frame_ns;

        self.accum.rasterizer.clear_ns += t.rasterizer.clear_ns;
        self.accum.rasterizer.count_ns += t.rasterizer.count_ns;
        self.accum.rasterizer.prefix_ns += t.rasterizer.prefix_ns;
        self.accum.rasterizer.ensure_refs_ns += t.rasterizer.ensure_refs_ns;
        self.accum.rasterizer.scatter_ns += t.rasterizer.scatter_ns;
        self.accum.rasterizer.tiles_ns += t.rasterizer.tiles_ns;

        self.accum.visible_chunks += t.visible_chunks;
        self.accum.primitives += t.primitives;
        self.accum.vertices += t.vertices;
        self.accum.tile_refs += t.tile_refs;

        self.samples += 1;

        if (self.samples >= window) {
            self.printAndReset();
        }
    }

    fn ms(ns: u64, samples: u32) f64 {
        return @as(f64, @floatFromInt(ns)) /
            @as(f64, @floatFromInt(samples)) /
            1_000_000.0;
    }

    fn avgUsize(v: usize, samples: u32) usize {
        return v / samples;
    }

    fn printAndReset(self: *RollingProfiler) void {
        const n = self.samples;
        const a = self.accum;

        std.debug.print(
            \\---- frame profile, avg over {d} frames ----
            \\frame:        {d:.3} ms
            \\drain chunks: {d:.3} ms
            \\begin frame:  {d:.3} ms
            \\input:        {d:.3} ms
            \\player:       {d:.3} ms
            \\camera:       {d:.3} ms
            \\sky:          {d:.3} ms
            \\update chunks:{d:.3} ms
            \\visible:      {d:.3} ms
            \\prim build:   {d:.3} ms
            \\rast clear:   {d:.3} ms
            \\rast count:   {d:.3} ms
            \\rast prefix:  {d:.3} ms
            \\rast ensure:  {d:.3} ms
            \\rast scatter: {d:.3} ms
            \\rast tiles:   {d:.3} ms
            \\overlay:      {d:.3} ms
            \\end frame:    {d:.3} ms
            \\visible chunks avg: {d}
            \\primitives avg:     {d}
            \\vertices avg:       {d}
            \\tile refs avg:      {d}
            \\
        , .{
            n,
            ms(a.frame_ns, n),
            ms(a.drain_chunks_ns, n),
            ms(a.begin_frame_ns, n),
            ms(a.input_ns, n),
            ms(a.player_update_ns, n),
            ms(a.camera_ns, n),
            ms(a.sky_ns, n),
            ms(a.update_chunks_ns, n),
            ms(a.visible_chunks_ns, n),
            ms(a.primitive_build_ns, n),
            ms(a.rasterizer.clear_ns, n),
            ms(a.rasterizer.count_ns, n),
            ms(a.rasterizer.prefix_ns, n),
            ms(a.rasterizer.ensure_refs_ns, n),
            ms(a.rasterizer.scatter_ns, n),
            ms(a.rasterizer.tiles_ns, n),
            ms(a.overlay_render_ns, n),
            ms(a.end_frame_ns, n),
            avgUsize(a.visible_chunks, n),
            avgUsize(a.primitives, n),
            avgUsize(a.vertices, n),
            avgUsize(a.tile_refs, n),
        });

        self.* = .{};
    }
};

pub const ProfTimer = struct {
    io: std.Io,
    clock: std.Io.Clock = .awake,
    last: std.Io.Timestamp,

    pub fn start(io: std.Io) ProfTimer {
        const clock: std.Io.Clock = .awake;
        return .{
            .io = io,
            .clock = clock,
            .last = clock.now(io),
        };
    }

    pub fn lap(self: *ProfTimer) u64 {
        const now = self.clock.now(self.io);
        const ns = self.last.durationTo(now).toNanoseconds();
        self.last = now;
        return @intCast(ns);
    }

    pub fn read(self: *ProfTimer) u64 {
        const now = self.clock.now(self.io);
        return @intCast(self.last.durationTo(now).toNanoseconds());
    }
};
