pub inline fn voxelIndex(size: usize, x: usize, y: usize, z: usize) usize {
    return x + y * size + z * size * size;
}

pub inline fn pixelIndex(size: usize, x: usize, y: usize) usize {
    return x + y * size;
}

pub inline fn packColor(r: u8, g: u8, b: u8) u32 {
    return 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}
