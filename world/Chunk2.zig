//! Once a `ChunkVersion` is published, nobody mutates it in place.
//! Writers allocate a new version, fully initialize it, then publish it
//! atomically. Readers load the published pointer and read that immutable
//! object. That matches RCU's publish/subscribe model.

const std = @import("std");

const BlockId = @import("Block.zig").BlockId;
const World = @import("World.zig").World;
const BitfieldViews = @import("Chunk.zig").BitfieldViews;
const Mesh = @import("../mesh/Mesh.zig").Mesh;
const ChunkCoord = @import("../math/types.zig").ChunkCoord;
const ChunkWorker = @import("ChunkWorker.zig").ChunkWorker;
const mesher = @import("../mesh/mesher.zig");

const AtomicUsize = std.atomic.Value(usize);

/// Stable identity stored in World's hashmap
const ChunkSlot = struct {
    current: std.atomic.Value(?*ChunkVersion),
    mesh: std.atomic.Value(?*Mesh),
    gen: AtomicUsize,
};

/// Immutable after publish
const ChunkVersion = struct {
    voxels: []const BlockId,
    bitfields: *const BitfieldViews,
};

// The worker loads the current published version under its own protection.
// That keeps the synchronization boundary clean.
const MeshJob = struct {
    coord: ChunkCoord,
    expectec_gen: usize,
};

// Submit a mesh job
fn submitMeshIfNeeded(worker: *ChunkWorker, slot: *ChunkSlot, coord: ChunkCoord) void {
    try worker.submitMeshJob(.{
        .coord = coord,
        .expected_gen = slot.gen.load(.acquire),
    });
}

// Publish a new generated version
fn publishGeneratedVersion(
    allocator: std.mem.Allocator,
    slot: *ChunkSlot,
    new_voxels: []const BlockId,
    new_bitfields: *const BitfieldViews,
) !u64 {
    const next_gen = slot.gen.load(.acquire) + 1;

    const ver = try allocator.create(ChunkVersion);
    ver.* = .{
        .bitfields = new_bitfields,
        .voxels = new_voxels,
    };

    const old = slot.current.swap(ver, .acq_rel);
    slot.gen.store(next_gen, .release);

    if (old) |p| retireChunkVersion(p); // do NOT free immediately

    return next_gen;
}

////////////////////////////////////////////////////////////////////////////////

fn processMeshJob(self: *ChunkWorker, world: *World, job: MeshJob) !void {
    self.participant.pin();
    defer self.participant.unpin();

    const slot = world.getChunkSlot(job.coord) orelse return;

    const base = slot.current.load(.acquire) orelse return;
    const base_gen = slot.gen.load(.acquire) orelse return;

    // Early stale rejection
    if (base_gen != job.expectec_gen) return;

    const pos_x = loadNeighborVersionPinned(world, .{ job.coord[0] + 1, job.coord[1], job.coord[2] });
    const neg_x = loadNeighborVersionPinned(world, .{ job.coord[0] - 1, job.coord[1], job.coord[2] });
    const pos_y = loadNeighborVersionPinned(world, .{ job.coord[0], job.coord[1] + 1, job.coord[2] });
    const neg_y = loadNeighborVersionPinned(world, .{ job.coord[0], job.coord[1] - 1, job.coord[2] });
    const pos_z = loadNeighborVersionPinned(world, .{ job.coord[0], job.coord[1], job.coord[2] + 1 });
    const neg_z = loadNeighborVersionPinned(world, .{ job.coord[0], job.coord[1], job.coord[2] - 1 });

    const result_mesh = try mesher.generateMesh(self.allocator, .{
        .coord = job.coord,
        .voxels = base.voxels,
        .chunk_bitfield_views = base.bitfields,
        .pos_x_neighbor_bitfields_solid_x = pos_x,
        .neg_x_neighbor_bitfields_solid_x = neg_x,
        .pos_y_neighbor_bitfields_solid_y = pos_y,
        .neg_y_neighbor_bitfields_solid_y = neg_y,
        .pos_z_neighbor_bitfields_solid_z = pos_z,
        .neg_z_neighbor_bitfields_solid_z = neg_z,
    });

    try self.mesh_result_buffer.push(.{
        .coord = job.coord,
        .source_gen = base_gen,
        .mesh = result_mesh,
    });
}

//// Applying the results

const MeshResult = struct { coord: ChunkCoord, source_gen: usize, mesh: *Mesh };

fn drainMeshResults(world: *World, worker: *ChunkWorker, allocator: std.mem.Allocator) void {
    // Potential mistake
    while (worker.pollMeshJob()) |res| {
        const slot = world.getChunkSlot(res.coord) orelse {
            res.mesh.deinit(allocator);
            allocator.destroy(res.mesh);
            continue;
        };

        const current_gen = slot.gen.load(.acquire);
        if (current_gen != res.source_gen) {
            // Stale result, drop it
            res.mesh.deinit(allocator);
            allocator.destroy(res.mesh);
            continue;
        }

        const current = slot.current.load(.acquire) orelse {
            res.mesh.deinit(allocator);
            allocator.destroy(res.mesh);
            continue;
        };

        current.mesh = res.mesh; // only this field is not part of the immutable payload
    }
}

//// RETIREMENT LIST /////////

const Participant = struct {
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    epoch: AtomicUsize = AtomicUsize.init(0),
};

const Retired = struct {
    ptr: *ChunkVersion,
    retire_epoch: u64,
};

var global_epoch = AtomicUsize.init(1);

var participants: [2]*Participant = undefined;
var retired_versions: std.ArrayList(Retired) = .empty;

fn pin(self: *Participant) void {
    const e = global_epoch.load(.seq_cst);
    self.epoch.store(e, .seq_cst);
    self.active.store(true, .seq_cst);
}

fn unpin(self: *Participant) void {
    self.active.store(false, .seq_cst);
}

fn retireChunkVersion(allocator: std.mem.Allocator, ptr: *ChunkVersion) void {
    const e = global_epoch.load(.seq_cst);
    retired_versions.append(allocator, .{ .ptr = ptr, .retire_epoch = e }) catch unreachable;
}

fn tryAdvanceEpochAndReclaim(allocator: std.mem.Allocator) void {
    const cur = global_epoch.load(.seq_cst);

    for (participants) |p| {
        if (p.active.load(.seq_cst) and p.epoch.load(.seq_cst) <= cur) {
            return; // some reader may still be referencing old versions
        }
    }

    _ = global_epoch.fetchAdd(1, .seq_cst);
    const safe_epoch = global_epoch.load(.seq_cst) - 1;

    var write_i: usize = 0;
    for (retired_versions.items) |r| {
        if (r.retire_epoch < safe_epoch) {
            allocator.free(r.ptr.voxels);
            allocator.destroy(@constCast(r.ptr.bitfields));
            allocator.destroy(r.ptr);
        } else {
            retired_versions.items[write_i] = r;
            write_i += 1;
        }
    }

    retired_versions.items.len = write_i;
}
