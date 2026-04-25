pub inline fn voxelIndex(size: usize, x: usize, y: usize, z: usize) usize {
    return x + y * size + z * size * size;
}

pub inline fn pixelIndex(size: usize, x: usize, y: usize) usize {
    return x + y * size;
}

pub inline fn ffi(comptime To: type, x: anytype) To {
    return @as(To, @floatFromInt(x));
}

pub inline fn iff(comptime To: type, x: anytype) To {
    return @as(To, @intFromFloat(x));
}
