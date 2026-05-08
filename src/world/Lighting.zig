const std = @import("std");

pub const Lighting = struct {
    queue: std.ArrayList(comptime T: type)
};
