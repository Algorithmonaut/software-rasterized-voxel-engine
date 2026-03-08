const Cube = @import("Cube.zig");
const std = @import("std");
const BlockTypes = @import("Atlas.zig").BlockTypes;

pub const Scene = struct {
    cubes: []Cube.Cube,

    pub fn init(allocator: std.mem.Allocator) !Scene {
        const cubes = try allocator.alloc(Cube.Cube, 10000);

        var i: usize = 0;
        while (i < 100) : (i += 1) {
            const block_type: BlockTypes = blk: {
                var t = BlockTypes.dirt;
                if (i % 3 == 0) t = BlockTypes.grass;
                if (i % 3 == 1) t = BlockTypes.stone;
                if (i % 3 == 2) t = BlockTypes.dirt;

                break :blk t;
            };

            var j: usize = 0;
            while (j < 100) : (j += 1) {
                const idx = i * 100 + j;
                cubes[idx] = Cube.Cube.init(.{
                    @as(f32, @floatFromInt(i)) * 2.0,
                    0,
                    @as(f32, @floatFromInt(j)) * 2.0,
                    0,
                }, block_type);
            }
        }

        return .{
            .cubes = cubes,
        };
    }
};
