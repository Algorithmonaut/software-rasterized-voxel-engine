const std = @import("std");

pub const ProfileStage = enum {
    /// Decide which voxel faces are visible
    face_extraction,
    /// Build those faces into mesh primitives (quads)
    meshing,
    /// Convert quads into raster triangles
    triangle_setup,
    /// First tile pass, count how many triangles touch each tile
    binning_count,
    /// Second tile pass, write triangle indices into each tile's triangle list
    binning_scatter,
    /// Per tile rasterization
    tile_raster,
    /// Blitting into the main fb
    framebuffer_blit,
};

const stage_count = @typeInfo(ProfileStage).@"enum".fields.len;

pub const StageStats = struct {
    total_ns: u64 = 0,
    hits: usize = 0,

    pub fn add(self: *StageStats, dt_ns: u64) void {
        self.total_ns += dt_ns;
        self.hits += 1;
    }
};

pub const Profiler = struct {
    stats: [stage_count]StageStats = [_]StageStats{.{}} ** stage_count,

    pub const Scope = struct {
        profiler: *Profiler,
        stage: ProfileStage,
        timer: std.time.Timer,

        pub fn end(self: *Scope) void {
            const dt_ns = self.timer.read();
            self.profiler.stats[@intFromEnum(self.stage)].add(dt_ns);
        }
    };

    pub fn begin(self: *Profiler, stage: ProfileStage) !Scope {
        return .{
            .profiler = self,
            .stage = stage,
            .timer = try std.time.Timer.start(),
        };
    }

    pub fn reset(self: *Profiler) void {
        for (&self.stats) |*s| {
            s.* = .{};
        }
    }

    pub fn mergeFrom(self: *Profiler, other: *const Profiler) void {
        for (&self.stats, other.stats) |*dst, src| {
            dst.total_ns += src.total_ns;
            dst.hits += src.hits;
        }
    }

    pub fn totalCpuNs(self: *const Profiler) u64 {
        var total: u64 = 0;
        for (self.stats) |s| total += s.total_ns;
        return total;
    }

    /// wall_ns: total execution time of the program
    pub fn printReport(self: *const Profiler, wall_ns: u64) void {
        const names = comptime stageNames();
        const total_cpu_ns = self.totalCpuNs();

        std.debug.print(
            "==== profile report ====\nframe wall time: {d:.3} ms | merged cpu time: {d:.3} ms\n\n",
            .{
                nsToMs(wall_ns),
                nsToMs(total_cpu_ns),
            },
        );

        std.debug.print(
            "{s:>18} | {s:>10} | {s:>8} | {s:>10} | {s:>8} | {s:>8}\n",
            .{
                "stage",
                "total ms",
                "hits",
                "avg us",
                "% cpu",
                "% frame",
            },
        );

        for (self.stats, 0..) |s, i| {
            if (s.hits == 0) continue;

            const avg_ns: u64 = s.total_ns / s.hits;
            const pct_cpu = 100.0 * @as(f64, @floatFromInt(s.total_ns)) /
                @as(f64, @floatFromInt(total_cpu_ns));
            const pct_frame = 100.0 * @as(f64, @floatFromInt(s.total_ns)) /
                @as(f64, @floatFromInt(wall_ns));

            std.debug.print(
                "{s:>18} | {d:>10.3} | {d:>8} | {d:>10.3} | {d:>8.2} | {d:>8.2}\n",
                .{
                    names[i],
                    nsToMs(s.total_ns),
                    s.hits,
                    nsToUs(avg_ns),
                    pct_cpu,
                    pct_frame,
                },
            );
        }

        std.debug.print("\n", .{});
    }

    fn stageNames() [stage_count][]const u8 {
        const fields = @typeInfo(ProfileStage).@"enum".fields;
        var arr: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| {
            arr[i] = f.name;
        }
        return arr;
    }

    fn nsToMs(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
    }

    fn nsToUs(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / 1_000.0;
    }
};
