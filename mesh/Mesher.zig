const std = @import("std");

const Chunk = @import("../world/Chunk.zig").Chunk;
const BitfieldViews = @import("../world/Chunk.zig").BitfieldViews;
const Atlas = @import("../Atlas.zig").Atlas;
const World = @import("../world/World.zig").World;

const Block = @import("../world/Block.zig");
const Quad = Block.Quad;
const BlockId = Block.BlockId;
const Face = Block.Face;
const UV = Block.UV;

const types = @import("../math/types.zig");
const Vec3i = types.Vec3i;
const PosVec = @Vector(3, usize);

const PlaneSet = [32][32]u32;

const PlaneKind = @import("Mesh.zig").PlaneKind;
const Mesh = @import("Mesh.zig").Mesh;

const CHUNK_SIZE = @import("../world/Chunk.zig").CHUNK_SIZE;

// BINARY CULLED MESHER | GENERATE PLANES //////////////////////////////////////

inline fn voxelIndex(size: usize, x: usize, y: usize, z: usize) usize {
    return x + y * size + z * size * size;
}

inline fn visiblePos(row: u32) u32 {
    return row & ~(row >> 1);
}

inline fn visibleNeg(row: u32) u32 {
    return row & ~(row << 1);
}

fn visiblePosWithNeighbor(row: u32, neighbor_first_bit: u32) u32 {
    const shifted = (row >> 1) | (neighbor_first_bit << 31);
    return row & ~shifted;
}

fn visibleNegWithNeighbor(row: u32, neighbor_last_bit: u32) u32 {
    const shifted = (row << 1) | neighbor_last_bit;
    return row & ~shifted;
}

//// X AXIS ////

fn scatterMaskX(
    planes: *PlaneSet,
    y: usize,
    z: usize,
    mask_in: u32,
) void {
    var mask = mask_in;
    while (mask != 0) {
        const x: usize = @ctz(mask);
        mask &= mask - 1;
        planes[x][y] |= (@as(u32, 1)) << @intCast(z);
    }
}

fn buildXPlanes(
    solid_x: *[32][32]u32,
    pos_x_neighbor_solid_x: ?*[32][32]u32,
    neg_x_neightbor_solid_x: ?*[32][32]u32,
    pos_x_planes: *PlaneSet,
    neg_x_planes: *PlaneSet,
) void {
    const size = CHUNK_SIZE;

    for (0..size) |y| {
        for (0..size) |z| {
            const row = solid_x[y][z];

            const pos_mask = if (pos_x_neighbor_solid_x) |adjacent|
                visiblePosWithNeighbor(row, adjacent[y][z] & @as(u32, 1))
            else
                visiblePos(row);

            const neg_mask = if (neg_x_neightbor_solid_x) |adjacent|
                visibleNegWithNeighbor(row, (adjacent[y][z] >> 31) & @as(u32, 1))
            else
                visibleNeg(row);

            scatterMaskX(pos_x_planes, y, z, pos_mask);
            scatterMaskX(neg_x_planes, y, z, neg_mask);
        }
    }
}

//// Y AXIS ////

fn scatterMaskY(
    planes: *PlaneSet,
    x: usize,
    z: usize,
    mask_in: u32,
) void {
    var mask = mask_in;
    while (mask != 0) {
        const y: usize = @ctz(mask);
        mask &= mask - 1;
        planes[y][x] |= (@as(u32, 1)) << @intCast(z);
    }
}

fn buildYPlanes(
    solid_y: *[32][32]u32,
    pos_y_neighbor_solid_y: ?*[32][32]u32,
    neg_y_neightbor_solid_y: ?*[32][32]u32,
    pos_y_planes: *PlaneSet,
    neg_y_planes: *PlaneSet,
) void {
    const size = CHUNK_SIZE;

    for (0..size) |x| {
        for (0..size) |z| {
            const row = solid_y[x][z];

            const pos_mask = if (pos_y_neighbor_solid_y) |adjacent|
                visiblePosWithNeighbor(row, adjacent[x][z] & @as(u32, 1))
            else
                visiblePos(row);

            const neg_mask = if (neg_y_neightbor_solid_y) |adjacent|
                visibleNegWithNeighbor(row, (adjacent[x][z] >> 31) & @as(u32, 1))
            else
                visibleNeg(row);

            scatterMaskY(pos_y_planes, x, z, pos_mask);
            scatterMaskY(neg_y_planes, x, z, neg_mask);
        }
    }
}

//// Z AXIS ////

fn scatterMaskZ(
    planes: *PlaneSet,
    x: usize,
    y: usize,
    mask_in: u32,
) void {
    var mask = mask_in;
    while (mask != 0) {
        const z: usize = @ctz(mask);
        mask &= mask - 1;
        planes[z][x] |= (@as(u32, 1)) << @intCast(y);
    }
}

fn buildZPlanes(
    solid_z: *[32][32]u32,
    pos_z_neighbor_solid_z: ?*[32][32]u32,
    neg_z_neighbor_solid_z: ?*[32][32]u32,
    pos_z_planes: *PlaneSet,
    neg_z_planes: *PlaneSet,
) void {
    const size = CHUNK_SIZE;

    for (0..size) |x| {
        for (0..size) |y| {
            const row = solid_z[x][y];

            const pos_mask = if (pos_z_neighbor_solid_z) |adjacent|
                visiblePosWithNeighbor(row, adjacent[x][y] & @as(u32, 1))
            else
                visiblePos(row);

            const neg_mask = if (neg_z_neighbor_solid_z) |adjacent|
                visibleNegWithNeighbor(row, (adjacent[x][y] >> 31) & @as(u32, 1))
            else
                visibleNeg(row);

            scatterMaskZ(pos_z_planes, x, y, pos_mask);
            scatterMaskZ(neg_z_planes, x, y, neg_mask);
        }
    }
}

//// GREEDY MESHER /////////////////////////////////////////////////////////////

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

/// Counts how many consecutive 1 bits appear in mask, starting at bit start
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
    voxels: []const BlockId,
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
                if (id != id0) {
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
                    if (id != id0) {
                        ok = false;
                        break;
                    }
                }

                if (!ok) break;
                height += 1;
            }

            try mesh.appendRenderQuad(allocator, kind, .{
                .block_id = id0,
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

pub fn generateLodMesh(
    world: *World,
    voxels: []const BlockId, // always 32^3 for now
    bitfields: *BitfieldViews,
    coord: Vec3i,
    allocator: std.mem.Allocator,
    mesh: *Mesh,
) !void {
    const size = CHUNK_SIZE;

    var pos_x_planes = std.mem.zeroes(PlaneSet);
    var neg_x_planes = std.mem.zeroes(PlaneSet);
    var pos_y_planes = std.mem.zeroes(PlaneSet);
    var neg_y_planes = std.mem.zeroes(PlaneSet);
    var pos_z_planes = std.mem.zeroes(PlaneSet);
    var neg_z_planes = std.mem.zeroes(PlaneSet);

    mesh.clear();

    //// X AXIS ////

    const pos_x_neighbor = world.getChunk(.{ coord[0] + 1, coord[1], coord[2] });
    const neg_x_neighbor = world.getChunk(.{ coord[0] - 1, coord[1], coord[2] });

    buildXPlanes(
        &bitfields.solid_x,
        if (pos_x_neighbor) |adj| &adj.bitfields.solid_x else null,
        if (neg_x_neighbor) |adj| &adj.bitfields.solid_x else null,
        &pos_x_planes,
        &neg_x_planes,
    );

    //// Y AXIS ////

    const pos_y_neighbor = world.getChunk(.{ coord[0], coord[1] + 1, coord[2] });
    const neg_y_neighbor = world.getChunk(.{ coord[0], coord[1] - 1, coord[2] });

    buildYPlanes(
        &bitfields.solid_y,
        if (pos_y_neighbor) |adj| &adj.bitfields.solid_y else null,
        if (neg_y_neighbor) |adj| &adj.bitfields.solid_y else null,
        &pos_y_planes,
        &neg_y_planes,
    );

    //// Z AXIS ////

    const pos_z_neighbor = world.getChunk(.{ coord[0], coord[1], coord[2] + 1 });
    const neg_z_neighbor = world.getChunk(.{ coord[0], coord[1], coord[2] - 1 });

    buildZPlanes(
        &bitfields.solid_z,
        if (pos_z_neighbor) |adj| &adj.bitfields.solid_z else null,
        if (neg_z_neighbor) |adj| &adj.bitfields.solid_z else null,
        &pos_z_planes,
        &neg_z_planes,
    );

    for (0..size) |i| {
        try greedyMergePlane(mesh, allocator, voxels, .pos_x, i, pos_x_planes[i]);
        try greedyMergePlane(mesh, allocator, voxels, .neg_x, i, neg_x_planes[i]);
        try greedyMergePlane(mesh, allocator, voxels, .pos_y, i, pos_y_planes[i]);
        try greedyMergePlane(mesh, allocator, voxels, .neg_y, i, neg_y_planes[i]);
        try greedyMergePlane(mesh, allocator, voxels, .pos_z, i, pos_z_planes[i]);
        try greedyMergePlane(mesh, allocator, voxels, .neg_z, i, neg_z_planes[i]);
    }
}

pub fn generateMesh(
    chunk: *Chunk,
    world: *World,
    allocator: std.mem.Allocator,
) !void {
    try generateLodMesh(
        world,
        &chunk.lods.lod0,
        &chunk.bitfields,
        chunk.coord,
        allocator,
        &chunk.mesh,
    );

    // WARN: Part of LOD implementation, do not remove

    // var data_lod1 = Chunk.getResizedVoxelDataAndBitfield(
    //     &chunk.lods.lod1,
    //     CHUNK_SIZE / 2,
    // );
    // try generateLodMesh(
    //     world,
    //     &data_lod1.voxels,
    //     &data_lod1.bitfields,
    //     chunk.coord,
    //     allocator,
    //     &chunk.meshes.lod1,
    // );
    //
    // var data_lod2 = Chunk.getResizedVoxelDataAndBitfield(
    //     &chunk.lods.lod2,
    //     CHUNK_SIZE / 4,
    // );
    // try generateLodMesh(
    //     world,
    //     &data_lod2.voxels,
    //     &data_lod2.bitfields,
    //     chunk.coord,
    //     allocator,
    //     &chunk.meshes.lod2,
    // );
    //
    // var data_lod3 = Chunk.getResizedVoxelDataAndBitfield(
    //     &chunk.lods.lod3,
    //     CHUNK_SIZE / 8,
    // );
    // try generateLodMesh(
    //     world,
    //     &data_lod3.voxels,
    //     &data_lod3.bitfields,
    //     chunk.coord,
    //     allocator,
    //     &chunk.meshes.lod3,
    // );
    //
    // var data_lod4 = Chunk.getResizedVoxelDataAndBitfield(
    //     &chunk.lods.lod4,
    //     CHUNK_SIZE / 16,
    // );
    // try generateLodMesh(
    //     world,
    //     &data_lod4.voxels,
    //     &data_lod4.bitfields,
    //     chunk.coord,
    //     allocator,
    //     &chunk.meshes.lod4,
    // );
}

//// JOB ///////////////////////////////////////////////////////////////////////

pub const ChunkJob = struct {
    chunk: *Chunk,
    // TODO: Remove this and pass adjacent chunks directly
    world: *World,
};

pub const Mesher = struct {
    allocator: std.mem.Allocator,

    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    jobs: std.ArrayList(ChunkJob),
    shutting_down: bool = false,

    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator) !Mesher {
        return .{
            .allocator = allocator,
            .jobs = try std.ArrayList(ChunkJob).initCapacity(allocator, 64),
        };
    }

    pub fn deinit(self: *Mesher) void {
        self.jobs.deinit(self.allocator);
    }

    pub fn start(self: *Mesher) !void {
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn stop(self: *Mesher) void {
        self.mutex.lock();
        self.shutting_down = true;
        self.cond.signal();
        self.mutex.unlock();

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn enqueue(self: *Mesher, job: ChunkJob) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.jobs.append(self.allocator, job);
        self.cond.signal();
    }

    fn workerMain(self: *Mesher) void {
        while (true) {
            self.mutex.lock();

            while (self.jobs.items.len == 0 and !self.shutting_down) {
                self.cond.wait(&self.mutex);
            }

            if (self.shutting_down and self.jobs.items.len == 0) {
                self.mutex.unlock();
                return;
            }

            const job = self.jobs.pop() orelse unreachable;
            self.mutex.unlock();

            job.chunk.queued = false;
            job.chunk.meshing = true;

            generateMesh(job.chunk, job.world, self.allocator) catch |err| {
                std.log.err("generateMesh failed: {}", .{err});
            };

            job.chunk.dirty = false;
            job.chunk.meshing = false;
        }
    }
};

//// MESHING INPUT /////////////////////////////////////////////////////////////

const MeshingInput = struct {
    voxels: []const BlockId, // always 32^3 for now
    bitfields: BitfieldViews,
    coord: Vec3i,
};
