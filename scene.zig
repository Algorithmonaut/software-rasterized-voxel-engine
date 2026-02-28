const Cube = @import("cube.zig");
const tex = @import("textures.zig");

pub const Scene = struct {
    cubes: [3]Cube.Cube,

    pub fn init() Scene {
        const cube1 = Cube.Cube.init(.{ 0, 0, 0, 0 }, tex.BlockTypes.grass);
        const cube2 = Cube.Cube.init(.{ 6, 0, 0, 0 }, tex.BlockTypes.stone);
        const cube3 = Cube.Cube.init(.{ 12, 0, 0, 0 }, tex.BlockTypes.dirt);

        const cubes = .{ cube1, cube2, cube3 };

        return .{
            .cubes = cubes,
        };
    }
};
