const mat = @import("matrix.zig");
const cfg = @import("config.zig");
const Vec3f = cfg.Vec3f;

pub const Camera = struct {
    view_mat: mat.Mat4f,
    from: Vec3f,
    to: Vec3f,

    pub fn init(from: Vec3f, to: Vec3f) Camera {
        return .{
            .view_mat = undefined,
            .from = from,
            .to = to,
        };
    }

    pub fn deinit(self: *Camera) void {
        _ = self;
    }
};
