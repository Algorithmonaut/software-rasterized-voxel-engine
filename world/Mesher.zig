const std = @import("std");

const Chunk = @import("../Chunk.zig").Chunk;
const Atlas = @import("../Atlas.zig").Atlas;
const World = @import("../World.zig").World;

const Block = @import("Block.zig");
const Quad = Block.Quad;
const BlockId = Block.BlockId;
const Face = Block.Face;
const UV = Block.UV;

const types = @import("../math/types.zig");
const Vec3i = types.Vec3i;
const PosVec = @Vector(3, usize);

const PlaneSet = [32][32]u32;

const FaceTemplate = struct {
    p0: Vec3i,
    p1: Vec3i,
    p2: Vec3i,
    p3: Vec3i,
};

const UvCoord = struct {
    left: usize,
    right: usize,
    top: usize,
    bottom: usize,
};

const PlaneKind = enum {
    pos_x,
    neg_x,
    pos_y,
    neg_y,
    pos_z,
    neg_z,
};

fn generateAtlasTileLocalUVs(tex_w: usize, tex_h: usize) UvCoord {
    return .{
        .left = 0,
        .right = tex_w,
        .top = 0,
        .bottom = tex_h,
    };
}

// P: BINARY CULLED MESHER | GENERATE PLANES ///////////////////////////////////

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
    chunk: *const Chunk,
    world: *World,
    pos_x_planes: *PlaneSet,
    neg_x_planes: *PlaneSet,
) void {
    const size = chunk.dimensions;

    const pos_neighbor = world.getChunk(.{
        chunk.coord[0] + 1,
        chunk.coord[1],
        chunk.coord[2],
    });

    const neg_neighbor = world.getChunk(.{
        chunk.coord[0] - 1,
        chunk.coord[1],
        chunk.coord[2],
    });

    // if (pos_neighbor) |adjacent| std.debug.assert(!adjacent.dirty);
    // if (neg_neighbor) |adjacent| std.debug.assert(!adjacent.dirty);

    for (0..size) |y| {
        for (0..size) |z| {
            const row = chunk.bitfields.solid_x[y][z];

            const pos_mask = if (pos_neighbor) |adjacent|
                visiblePosWithNeighbor(row, adjacent.bitfields.solid_x[y][z] & @as(u32, 1))
            else
                visiblePos(row);

            const neg_mask = if (neg_neighbor) |adjacent|
                visibleNegWithNeighbor(row, (adjacent.bitfields.solid_x[y][z] >> 31) & @as(u32, 1))
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
    chunk: *const Chunk,
    world: *World,
    pos_y_planes: *PlaneSet,
    neg_y_planes: *PlaneSet,
) void {
    const size = chunk.dimensions;

    const pos_neighbor = world.getChunk(.{
        chunk.coord[0],
        chunk.coord[1] + 1,
        chunk.coord[2],
    });

    const neg_neighbor = world.getChunk(.{
        chunk.coord[0],
        chunk.coord[1] - 1,
        chunk.coord[2],
    });

    // if (pos_neighbor) |adjacent| std.debug.assert(!adjacent.dirty);
    // if (neg_neighbor) |adjacent| std.debug.assert(!adjacent.dirty);

    for (0..size) |x| {
        for (0..size) |z| {
            const row = chunk.bitfields.solid_y[x][z];

            const pos_mask = if (pos_neighbor) |adjacent|
                visiblePosWithNeighbor(row, adjacent.bitfields.solid_y[x][z] & @as(u32, 1))
            else
                visiblePos(row);

            const neg_mask = if (neg_neighbor) |adjacent|
                visibleNegWithNeighbor(row, (adjacent.bitfields.solid_y[x][z] >> 31) & @as(u32, 1))
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
    chunk: *const Chunk,
    world: *World,
    pos_z_planes: *PlaneSet,
    neg_z_planes: *PlaneSet,
) void {
    const size = chunk.dimensions;

    const pos_neighbor = world.getChunk(.{
        chunk.coord[0],
        chunk.coord[1],
        chunk.coord[2] + 1,
    });

    const neg_neighbor = world.getChunk(.{
        chunk.coord[0],
        chunk.coord[1],
        chunk.coord[2] - 1,
    });

    // if (pos_neighbor) |adjacent| std.debug.assert(!adjacent.dirty);
    // if (neg_neighbor) |adjacent| std.debug.assert(!adjacent.dirty);

    for (0..size) |x| {
        for (0..size) |y| {
            const row = chunk.bitfields.solid_z[x][y];

            const pos_mask = if (pos_neighbor) |adjacent|
                visiblePosWithNeighbor(row, adjacent.bitfields.solid_z[x][y] & @as(u32, 1))
            else
                visiblePos(row);

            const neg_mask = if (neg_neighbor) |adjacent|
                visibleNegWithNeighbor(row, (adjacent.bitfields.solid_z[x][y] >> 31) & @as(u32, 1))
            else
                visibleNeg(row);

            scatterMaskZ(pos_z_planes, x, y, pos_mask);
            scatterMaskZ(neg_z_planes, x, y, neg_mask);
        }
    }
}

//// P: GREEDY MESHER //////////////////////////////////////////////////////////

const QuadLocalUv = struct {
    uv0: UV,
    uv1: UV,
    uv2: UV,
    uv3: UV,
};

// TODO: UNDERSTAND THIS CODE, TIRED TONIGHT
fn localUVsFor(comptime kind: PlaneKind, width: usize, height: usize) QuadLocalUv {
    const u_extent: f32 = @floatFromInt(switch (kind) {
        .pos_x, .neg_x => width * 16,
        .pos_y, .neg_y, .pos_z, .neg_z => height * 16,
    });

    const v_extent: f32 = @floatFromInt(switch (kind) {
        .pos_x, .neg_x => height * 16,
        .pos_y, .neg_y, .pos_z, .neg_z => width * 16,
    });

    return switch (kind) {
        .pos_x => .{
            .uv0 = .{ 0, v_extent },
            .uv1 = .{ 0, 0 },
            .uv2 = .{ u_extent, 0 },
            .uv3 = .{ u_extent, v_extent },
        },

        .neg_x => .{
            .uv0 = .{ u_extent, v_extent },
            .uv1 = .{ u_extent, 0 },
            .uv2 = .{ 0, 0 },
            .uv3 = .{ 0, v_extent },
        },

        .pos_y => .{
            .uv0 = .{ 0, v_extent },
            .uv1 = .{ 0, 0 },
            .uv2 = .{ u_extent, 0 },
            .uv3 = .{ u_extent, v_extent },
        },

        .neg_y => .{
            .uv0 = .{ 0, 0 },
            .uv1 = .{ 0, v_extent },
            .uv2 = .{ u_extent, v_extent },
            .uv3 = .{ u_extent, 0 },
        },

        .pos_z => .{
            .uv0 = .{ u_extent, v_extent },
            .uv1 = .{ u_extent, 0 },
            .uv2 = .{ 0, 0 },
            .uv3 = .{ 0, v_extent },
        },

        .neg_z => .{
            .uv0 = .{ 0, v_extent },
            .uv1 = .{ 0, 0 },
            .uv2 = .{ u_extent, 0 },
            .uv3 = .{ u_extent, v_extent },
        },
    };
}

fn makeTexturedQuad(
    p0: PosVec,
    p1: PosVec,
    p2: PosVec,
    p3: PosVec,
    local_uv: QuadLocalUv,
    block_id: BlockId,
    face: Face,
) Quad {
    return .{
        .v0 = .{ .pos = p0, .uv = local_uv.uv0 },
        .v1 = .{ .pos = p1, .uv = local_uv.uv1 },
        .v2 = .{ .pos = p2, .uv = local_uv.uv2 },
        .v3 = .{ .pos = p3, .uv = local_uv.uv3 },

        // Remove magic number
        .u = @as(usize, @intFromEnum(face)) * 16,
        .v = @as(usize, @intFromEnum(block_id)) * 16,
        .atlas_tile_size = 16,
    };
}

fn appendMergedQuad(
    mesh: *std.ArrayList(Quad),
    allocator: std.mem.Allocator,
    comptime kind: PlaneKind,
    plane_index: usize,
    row: usize,
    col: usize,
    width: usize,
    height: usize,
    id: BlockId,
) !void {
    const face = faceFor(kind);
    // NOTE: Remove magic number

    // .p0 = .{ 1, 0, 1 }, .p1 = .{ 1, 1, 1 }, .p2 = .{ 0, 1, 1 }, .p3 = .{ 0, 0, 1 } // back
    // .p0 = .{ 0, 0, 0 }, .p1 = .{ 0, 1, 0 }, .p2 = .{ 1, 1, 0 }, .p3 = .{ 1, 0, 0 } // front
    // .p0 = .{ 0, 0, 1 }, .p1 = .{ 0, 1, 1 }, .p2 = .{ 0, 1, 0 }, .p3 = .{ 0, 0, 0 } // left
    // .p0 = .{ 1, 0, 0 }, .p1 = .{ 1, 1, 0 }, .p2 = .{ 1, 1, 1 }, .p3 = .{ 1, 0, 1 } // right
    // .p0 = .{ 0, 0, 1 }, .p1 = .{ 0, 0, 0 }, .p2 = .{ 1, 0, 0 }, .p3 = .{ 1, 0, 1 } // bottom
    // .p0 = .{ 0, 1, 0 }, .p1 = .{ 0, 1, 1 }, .p2 = .{ 1, 1, 1 }, .p3 = .{ 1, 1, 0 } // top

    const p0: PosVec, const p1: PosVec, const p2: PosVec, const p3: PosVec = switch (kind) {
        // +X / right face: fixed x, rows=y, cols=z
        .pos_x => .{
            .{ plane_index + 1, row, col },
            .{ plane_index + 1, row + height, col },
            .{ plane_index + 1, row + height, col + width },
            .{ plane_index + 1, row, col + width },
        },

        // -X / left face: fixed x, rows=y, cols=z
        .neg_x => .{
            .{ plane_index, row, col + width },
            .{ plane_index, row + height, col + width },
            .{ plane_index, row + height, col },
            .{ plane_index, row, col },
        },

        // +Y / top face: fixed y, rows=x, cols=z
        .pos_y => .{
            .{ row, plane_index + 1, col },
            .{ row, plane_index + 1, col + width },
            .{ row + height, plane_index + 1, col + width },
            .{ row + height, plane_index + 1, col },
        },

        // -Y / bottom face: fixed y, rows=x, cols=z
        .neg_y => .{
            .{ row, plane_index, col + width },
            .{ row, plane_index, col },
            .{ row + height, plane_index, col },
            .{ row + height, plane_index, col + width },
        },

        // +Z / back face: fixed z, rows=x, cols=y
        .pos_z => .{
            .{ row + height, col, plane_index + 1 },
            .{ row + height, col + width, plane_index + 1 },
            .{ row, col + width, plane_index + 1 },
            .{ row, col, plane_index + 1 },
        },

        // -Z / front face: fixed z, rows=x, cols=y
        .neg_z => .{
            .{ row, col, plane_index },
            .{ row, col + width, plane_index },
            .{ row + height, col + width, plane_index },
            .{ row + height, col, plane_index },
        },
    };

    const local_uv = localUVsFor(kind, width, height);
    const quad = makeTexturedQuad(p0, p1, p2, p3, local_uv, id, face);
    try mesh.append(allocator, quad);
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

/// Counts how many consecutive 1 bits appear in mask, starting at bit start
fn runWidthFromSlow(mask: u32, start: usize, size: usize) usize {
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

fn faceFor(comptime kind: PlaneKind) Face {
    return switch (kind) {
        .pos_x => .right,
        .neg_x => .left,
        .pos_y => .top,
        .neg_y => .bottom,
        .pos_z => .back,
        .neg_z => .front,
    };
}

fn cellToVoxel(
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
    mesh: *std.ArrayList(Quad),
    allocator: std.mem.Allocator,
    voxels: []const BlockId,
    size: usize,
    comptime kind: PlaneKind,
    plane_index: usize,
    plane_in: [32]u32,
) !void {
    var plane = plane_in;

    var row: usize = 0;
    while (row < size) : (row += 1) {
        while (plane[row] != 0) {
            const col: usize = @intCast(@ctz(plane[row]));
            const xyz0 = cellToVoxel(kind, plane_index, row, col);
            const id0 = voxels[voxelIndex(size, xyz0.x, xyz0.y, xyz0.z)];

            var width = runWidthFromSlow(plane[row], col, size);

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

            try appendMergedQuad(
                mesh,
                allocator,
                kind,
                plane_index,
                row,
                col,
                width,
                height,
                id0,
            );

            var r = row;
            while (r < row + height) : (r += 1) {
                plane[r] &= ~mask;
            }
        }
    }
}

//// P: MAIN ///////////////////////////////////////////////////////////////////

pub fn generateMesh(
    chunk: *Chunk,
    world: *World,
    allocator: std.mem.Allocator,
) !void {
    var pos_x_planes: PlaneSet = [_][32]u32{[_]u32{0} ** 32} ** 32;
    var neg_x_planes: PlaneSet = [_][32]u32{[_]u32{0} ** 32} ** 32;

    var pos_y_planes: PlaneSet = [_][32]u32{[_]u32{0} ** 32} ** 32;
    var neg_y_planes: PlaneSet = [_][32]u32{[_]u32{0} ** 32} ** 32;

    var pos_z_planes: PlaneSet = [_][32]u32{[_]u32{0} ** 32} ** 32;
    var neg_z_planes: PlaneSet = [_][32]u32{[_]u32{0} ** 32} ** 32;

    const size = chunk.dimensions;

    var mesh = try std.ArrayList(Quad).initCapacity(allocator, size);

    buildXPlanes(chunk, world, &pos_x_planes, &neg_x_planes);
    buildYPlanes(chunk, world, &pos_y_planes, &neg_y_planes);
    buildZPlanes(chunk, world, &pos_z_planes, &neg_z_planes);

    for (0..size) |i| {
        try greedyMergePlane(&mesh, allocator, chunk.voxels, size, .pos_x, i, pos_x_planes[i]);
        try greedyMergePlane(&mesh, allocator, chunk.voxels, size, .neg_x, i, neg_x_planes[i]);
        try greedyMergePlane(&mesh, allocator, chunk.voxels, size, .pos_y, i, pos_y_planes[i]);
        try greedyMergePlane(&mesh, allocator, chunk.voxels, size, .neg_y, i, neg_y_planes[i]);
        try greedyMergePlane(&mesh, allocator, chunk.voxels, size, .pos_z, i, pos_z_planes[i]);
        try greedyMergePlane(&mesh, allocator, chunk.voxels, size, .neg_z, i, neg_z_planes[i]);
    }

    chunk.mesh.clearAndFree(allocator);
    chunk.mesh = mesh;
}

//// P: JOB ////////////////////////////////////////////////////////////////////

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
