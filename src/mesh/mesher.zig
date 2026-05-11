const std = @import("std");
const types = @import("../types.zig");
const constants = @import("../constants.zig");
const helpers = @import("../helpers.zig");

const I3 = types.I3;
const Block = types.Block;
const Bitfields = types.Bitfields;
const ChunkCoord = types.ChunkCoord;
const Mesh = @import("Mesh.zig").Mesh;
const PlaneKind = @import("Mesh.zig").PlaneKind;
const World = @import("../world/World.zig").World;
const ChunkVersion = @import("../world/chunk.zig").ChunkVersion;

const PlaneSet = [32][32]u32;
const PosVec = @Vector(3, usize);
const BitPlaneView = [32][32]u32; // TODO: Remove this from here

const voxelIndex = helpers.voxelIndex;

const CHUNK_SIZE = constants.CHUNK_SIZE;

comptime {
    std.debug.assert(CHUNK_SIZE == 32);
}

fn visiblePos(source_row: u32, occluder_row: u32, neighbor_first_occluder_bit: u32) u32 {
    const blockers = (occluder_row >> 1) | (neighbor_first_occluder_bit << 31);
    return source_row & ~blockers;
}

fn visibleNeg(source_row: u32, occluder_row: u32, neighbor_last_occluder_bit: u32) u32 {
    const blockers = (occluder_row << 1) | neighbor_last_occluder_bit;
    return source_row & ~blockers;
}

inline fn scatterMask(planes: *PlaneSet, row: usize, col: usize, mask_in: u32) void {
    var mask = mask_in;

    while (mask != 0) {
        const fixed: usize = @ctz(mask);
        mask &= mask - 1;

        planes[fixed][row] |= @as(u32, 1) << @intCast(col);
    }
}

fn buildAxisPlanes(
    source: *const BitPlaneView,
    occluder: *const BitPlaneView,
    pos_neighbor_occluder: ?*const BitPlaneView,
    neg_neighbor_occluder: ?*const BitPlaneView,
    pos_planes: *PlaneSet,
    neg_planes: *PlaneSet,
) void {
    const size = CHUNK_SIZE;

    for (0..size) |row| {
        for (0..size) |col| {
            const source_row = source[row][col];
            const occluder_row = occluder[row][col];

            const neighbor_pos_occluder_bit =
                if (pos_neighbor_occluder) |n| n[row][col] & 1 else 0;
            const neighbor_neg_occluder_bit =
                if (neg_neighbor_occluder) |n| (n[row][col] >> 31) & 1 else 0;

            const pos_mask = visiblePos(source_row, occluder_row, neighbor_pos_occluder_bit);
            const neg_mask = visibleNeg(source_row, occluder_row, neighbor_neg_occluder_bit);

            scatterMask(pos_planes, row, col, pos_mask);
            scatterMask(neg_planes, row, col, neg_mask);
        }
    }
}

/// Returns a bitmask with exactly width consecutive 1s starting at bit start.
fn rectMask(start: usize, width: usize) u32 {
    if (width >= 32) return std.math.maxInt(u32);
    // Example with start = 3, width = 4
    // STEP 1 | 0b00000001
    // STEP 2 | 0b00010000
    // STEP 3 | 0b00001111
    // STEP 4 | 0b01111000
    return ((@as(u32, 1) << @intCast(width)) - 1) << @intCast(start);
}

/// Counts how many consecutive 1 bits appear in mask, starting at bit start.
fn runWidthFromStart(mask: u32, start: usize) usize {
    const size = CHUNK_SIZE;

    var width: usize = 0;
    var i = start;
    while (i < size) : (i += 1) {
        const bit = (@as(u32, 1) << @intCast(i));
        if ((mask & bit) == 0) break;
        width += 1;
    }

    return width;
}

const voxelCoord = struct { x: usize, y: usize, z: usize };

inline fn cellToVoxel(
    comptime kind: PlaneKind,
    plane_index: usize,
    row: usize,
    col: usize,
) voxelCoord {
    return switch (kind) {
        .pos_x, .neg_x => .{ .x = plane_index, .y = row, .z = col },
        .pos_y, .neg_y => .{ .x = row, .y = plane_index, .z = col },
        .pos_z, .neg_z => .{ .x = row, .y = col, .z = plane_index },
    };
}

fn greedyMergePlane(
    mesh: *Mesh,
    allocator: std.mem.Allocator,
    voxels: []const Block,
    comptime kind: PlaneKind,
    plane_index: usize,
    plane_in: [32]u32,
) !void {
    const size = CHUNK_SIZE;

    var plane = plane_in;

    var row: usize = 0;
    while (row < size) : (row += 1) {
        while (plane[row] != 0) {
            const col: usize = @intCast(@ctz(plane[row]));
            const xyz0 = cellToVoxel(kind, plane_index, row, col);
            const id0 = voxels[voxelIndex(size, xyz0.x, xyz0.y, xyz0.z)];

            var width = runWidthFromStart(plane[row], col);

            var c = col;
            while (c < col + width) : (c += 1) {
                const xyz = cellToVoxel(kind, plane_index, row, c);
                const id = voxels[voxelIndex(size, xyz.x, xyz.y, xyz.z)];
                if (!std.meta.eql(id, id0)) {
                    width = c - col;
                    break;
                }
            }

            std.debug.assert(width > 0);

            const mask = rectMask(col, width);

            var height: usize = 1;
            while (row + height < size) {
                if ((plane[row + height] & mask) != mask) break;

                var ok = true;
                c = col;
                while (c < col + width) : (c += 1) {
                    const xyz = cellToVoxel(kind, plane_index, row + height, c);
                    const id = voxels[voxelIndex(size, xyz.x, xyz.y, xyz.z)];
                    if (!std.meta.eql(id, id0)) {
                        ok = false;
                        break;
                    }
                }

                if (!ok) break;
                height += 1;
            }

            try mesh.appendRenderQuad(allocator, kind, .{
                .voxel = id0,
                // TODO: Maybe remove type casting
                .col = @intCast(col),
                .row = @intCast(row),
                .fixed = @intCast(plane_index),
                .width = @intCast(width),
                .height = @intCast(height),
            });

            var r = row;
            while (r < row + height) : (r += 1) {
                plane[r] &= ~mask;
            }
        }
    }
}

//// MAIN //////////////////////////////////////////////////////////////////////

pub const MeshJob = struct {
    coord: ChunkCoord,
    source_gen: usize,

    center: *ChunkVersion,

    pos_x: ?*ChunkVersion = null,
    neg_x: ?*ChunkVersion = null,
    pos_y: ?*ChunkVersion = null,
    neg_y: ?*ChunkVersion = null,
    pos_z: ?*ChunkVersion = null,
    neg_z: ?*ChunkVersion = null,

    pub fn deinit(self: MeshJob, allocator: std.mem.Allocator) void {
        self.center.releaseVersion(allocator);
        if (self.pos_x) |v| v.releaseVersion(allocator);
        if (self.neg_x) |v| v.releaseVersion(allocator);
        if (self.pos_y) |v| v.releaseVersion(allocator);
        if (self.neg_y) |v| v.releaseVersion(allocator);
        if (self.pos_z) |v| v.releaseVersion(allocator);
        if (self.neg_z) |v| v.releaseVersion(allocator);
    }
};

pub const MeshResult = struct {
    coord: ChunkCoord,
    source_gen: usize,
    mesh: *Mesh,
};

pub fn makeMeshJob(world: *World, coord: ChunkCoord) ?MeshJob {
    const slot = world.getChunkSlot(coord) orelse return null;
    const center = slot.current orelse return null;
    center.retainVersion();
    errdefer center.releaseVersion(world.allocator);

    var job = MeshJob{
        .coord = coord,
        .source_gen = slot.gen.load(.acquire),
        .center = center,
    };

    inline for ([_]struct { field: []const u8, dc: ChunkCoord }{
        .{ .field = "pos_x", .dc = .{ 1, 0, 0 } },
        .{ .field = "neg_x", .dc = .{ -1, 0, 0 } },
        .{ .field = "pos_y", .dc = .{ 0, 1, 0 } },
        .{ .field = "neg_y", .dc = .{ 0, -1, 0 } },
        .{ .field = "pos_z", .dc = .{ 0, 0, 1 } },
        .{ .field = "neg_z", .dc = .{ 0, 0, -1 } },
    }) |entry| {
        const ncoord = coord + entry.dc;
        if (world.getChunkSlot(ncoord)) |nslot| {
            if (nslot.current) |nver| {
                nver.retainVersion();
                @field(job, entry.field) = nver;
            }
        }
    }

    return job;
}

pub fn processMeshJob(allocator: std.mem.Allocator, job: MeshJob) !MeshResult {
    const size = CHUNK_SIZE;

    var pos_x_planes = std.mem.zeroes(PlaneSet);
    var neg_x_planes = std.mem.zeroes(PlaneSet);
    var pos_y_planes = std.mem.zeroes(PlaneSet);
    var neg_y_planes = std.mem.zeroes(PlaneSet);
    var pos_z_planes = std.mem.zeroes(PlaneSet);
    var neg_z_planes = std.mem.zeroes(PlaneSet);

    buildAxisPlanes(
        &job.center.bitfields.renderable_x,
        &job.center.bitfields.occluder_x,
        if (job.pos_x) |v| &v.bitfields.occluder_x else null,
        if (job.neg_x) |v| &v.bitfields.occluder_x else null,
        &pos_x_planes,
        &neg_x_planes,
    );

    buildAxisPlanes(
        &job.center.bitfields.renderable_y,
        &job.center.bitfields.occluder_y,
        if (job.pos_y) |v| &v.bitfields.occluder_y else null,
        if (job.neg_y) |v| &v.bitfields.occluder_y else null,
        &pos_y_planes,
        &neg_y_planes,
    );

    buildAxisPlanes(
        &job.center.bitfields.renderable_z,
        &job.center.bitfields.occluder_z,
        if (job.pos_z) |v| &v.bitfields.occluder_z else null,
        if (job.neg_z) |v| &v.bitfields.occluder_z else null,
        &pos_z_planes,
        &neg_z_planes,
    );

    const mesh = try allocator.create(Mesh);
    mesh.* = .{};

    for (0..size) |i| {
        try greedyMergePlane(mesh, allocator, job.center.voxels, .pos_x, i, pos_x_planes[i]);
        try greedyMergePlane(mesh, allocator, job.center.voxels, .neg_x, i, neg_x_planes[i]);
        try greedyMergePlane(mesh, allocator, job.center.voxels, .pos_y, i, pos_y_planes[i]);
        try greedyMergePlane(mesh, allocator, job.center.voxels, .neg_y, i, neg_y_planes[i]);
        try greedyMergePlane(mesh, allocator, job.center.voxels, .pos_z, i, pos_z_planes[i]);
        try greedyMergePlane(mesh, allocator, job.center.voxels, .neg_z, i, neg_z_planes[i]);
    }

    return .{
        .coord = job.coord,
        .source_gen = job.source_gen,
        .mesh = mesh,
    };
}
