const Cube = @import("cube.zig");
const BlockTypes = @import("Atlas.zig").BlockTypes;

pub const Scene = struct {
    cubes: [100]Cube.Cube,

    pub fn init() Scene {
        var cubes: [100]Cube.Cube = undefined;

        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const block_type: BlockTypes = blk: {
                var t = BlockTypes.dirt;
                if (i % 3 == 0) t = BlockTypes.grass;
                if (i % 3 == 1) t = BlockTypes.stone;
                if (i % 3 == 2) t = BlockTypes.dirt;

                break :blk t;
            };

            var j: usize = 0;
            while (j < 10) : (j += 1) {
                const idx = i * 10 + j;
                cubes[idx] = Cube.Cube.init(.{
                    @as(f32, @floatFromInt(i)) * 4,
                    @as(f32, @floatFromInt(j)) * 4 - 10,
                    20 + @as(f32, @floatFromInt(i % 3)),
                    0,
                }, block_type);
            }
        }

        return .{
            .cubes = cubes,
        };
    }
};
