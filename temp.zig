const std = @import("std");
const Block = @import("world/Block.zig");
const Quad = Block.Quad;
const ChunkCoord = @import("math/types.zig").ChunkCoord;

pub const MeshJob = struct {
    coord: ChunkCoord,
    size: usize,
    voxels: []u8, // replace with []BlockId
    // add copied bitfields / neighbors here
};

pub const MeshResult = struct {
    coord: ChunkCoord,
    mesh: std.ArrayList(Quad),
};

pub const MeshingService = struct {
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,

    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    jobs: std.ArrayList(MeshJob),
    results: std.ArrayList(MeshResult),

    stop: bool = false,

    pub fn init(allocator: std.mem.Allocator) !MeshingService {
        var self = MeshingService{
            .allocator = allocator,
            .jobs = try std.ArrayList(MeshJob).initCapacity(allocator, 64),
            .results = try std.ArrayList(MeshResult).initCapacity(allocator, 64),
        };

        self.thread = try std.Thread.spawn(.{}, workerMain, .{&self});
        return self;
    }

    pub fn deinit(self: *MeshingService) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.stop = true;
            self.cond.signal();
        }

        if (self.thread) |t| t.join();

        // clean queued jobs not processed
        for (self.jobs.items) |job| {
            self.allocator.free(job.voxels);
        }
        self.jobs.deinit(self.allocator);

        // clean unconsumed results
        for (self.results.items) |*res| {
            res.mesh.deinit(self.allocator);
        }
        self.results.deinit(self.allocator);
    }

    pub fn submit(self: *MeshingService, job: MeshJob) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.jobs.append(self.allocator, job);
        self.cond.signal();
    }

    pub fn tryPopResult(self: *MeshingService) ?MeshResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.results.items.len == 0) return null;

        const res = self.results.items[0];
        _ = self.results.orderedRemove(0);
        return res;
    }

    fn workerMain(self: *MeshingService) !void {
        while (true) {
            var job: MeshJob = undefined;

            {
                self.mutex.lock();
                defer self.mutex.unlock();

                while (self.jobs.items.len == 0 and !self.stop) {
                    self.cond.wait(&self.mutex);
                }

                if (self.stop and self.jobs.items.len == 0) return;

                job = self.jobs.items[0];
                _ = self.jobs.orderedRemove(0);
            }

            const mesh = try buildMeshFromJob(self.allocator, job);

            self.allocator.free(job.voxels);

            self.mutex.lock();
            defer self.mutex.unlock();

            try self.results.append(self.allocator, .{
                .coord = job.coord,
                .mesh = mesh,
            });
        }
    }
};

fn buildMeshFromJob(
    allocator: std.mem.Allocator,
    job: MeshJob,
) !std.ArrayList(Quad) {
    // var mesh = try std.ArrayList(Quad).initCapacity(allocator, 64);

    // call a mesher that works from job data only
    // try chunk_mesher.generateMeshFromSnapshot(&mesh, allocator, job);

    _ = job;
    _ = allocator;
    // return mesh;
}
