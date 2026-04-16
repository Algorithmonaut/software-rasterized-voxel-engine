const std = @import("std");

const TerrainGenerator = @import("TerrainGenerator.zig").TerrainGenerator;
const GenerationJob = @import("TerrainGenerator.zig").GenerationJob;
const GenerationResult = @import("TerrainGenerator.zig").GenerationResult;

const SpscRingBuffer = @import("../DS/SpscRingBuffer.zig").SpscRingBuffer;
const mesher = @import("../mesh/mesher.zig");
const MeshJob = mesher.MeshJob;
const MeshResult = mesher.MeshResult;

const DEBUG_SINGLE_THREADED = @import("../main.zig").DEBUG_SINGLE_THREADED;
// const DEBUG_SINGLE_THREADED = true;

pub const ChunkWorker = struct {
    allocator: std.mem.Allocator,
    terrain_generator: *TerrainGenerator,

    thread: ?std.Thread = null,

    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    stopping: bool = false,

    mesh_job_buffer: SpscRingBuffer(MeshJob),
    mesh_result_buffer: SpscRingBuffer(MeshResult),
    generation_job_buffer: SpscRingBuffer(GenerationJob),
    generation_result_buffer: SpscRingBuffer(GenerationResult),

    pub fn init(
        allocator: std.mem.Allocator,
        comptime ring_buffer_capacity: usize,
        terrain_generator: *TerrainGenerator,
    ) !ChunkWorker {
        return .{
            .mesh_job_buffer = try SpscRingBuffer(MeshJob).init(allocator, ring_buffer_capacity),
            .mesh_result_buffer = try SpscRingBuffer(MeshResult).init(allocator, ring_buffer_capacity),
            .generation_job_buffer = try SpscRingBuffer(GenerationJob).init(allocator, ring_buffer_capacity),
            .generation_result_buffer = try SpscRingBuffer(GenerationResult).init(allocator, ring_buffer_capacity),
            .allocator = allocator,
            .terrain_generator = terrain_generator,
        };
    }

    pub fn deinit(self: *ChunkWorker, allocator: std.mem.Allocator) void {
        self.mesh_job_buffer.deinit(allocator);
        self.mesh_result_buffer.deinit(allocator);
        self.generation_job_buffer.deinit(allocator);
        self.generation_result_buffer.deinit(allocator);
    }

    pub fn start(self: *ChunkWorker) !void {
        if (DEBUG_SINGLE_THREADED) return;
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn stop(self: *ChunkWorker) void {
        if (DEBUG_SINGLE_THREADED) return;

        self.mutex.lock();
        self.stopping = true;
        self.cond.signal();
        self.mutex.unlock();

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub inline fn submitMeshJob(self: *ChunkWorker, mesh_job: MeshJob) !void {
        if (DEBUG_SINGLE_THREADED) {
            const result = try mesher.generateMesh(self.allocator, mesh_job);
            try self.mesh_result_buffer.push(result);
        } else {
            self.mutex.lock();
            defer self.mutex.unlock();

            try self.mesh_job_buffer.push(mesh_job);
            self.cond.signal();
        }
    }

    pub inline fn pollMeshJob(self: *ChunkWorker) ?MeshResult {
        return self.mesh_result_buffer.pop();
    }

    pub inline fn submitGenerationJob(self: *ChunkWorker, job: GenerationJob) !void {
        if (DEBUG_SINGLE_THREADED) {
            const result = try self.terrain_generator.fillChunkVoxels(self.allocator, job);
            try self.generation_result_buffer.push(result);
        } else {
            self.mutex.lock();
            defer self.mutex.unlock();

            try self.generation_job_buffer.push(job);
            self.cond.signal();
        }
    }

    pub inline fn pollGenerationResult(self: *ChunkWorker) ?GenerationResult {
        return self.generation_result_buffer.pop();
    }

    fn pushGenerationResultRetry(self: *ChunkWorker, result: GenerationResult) void {
        while (true) {
            self.generation_result_buffer.push(result) catch |err| switch (err) {
                error.Full => {
                    std.Thread.yield() catch {};
                    continue;
                },
                else => return,
            };
            break;
        }
    }

    fn pushMeshResultRetry(self: *ChunkWorker, result: MeshResult) void {
        while (true) {
            self.mesh_result_buffer.push(result) catch |err| switch (err) {
                error.Full => {
                    std.Thread.yield() catch {};
                    continue;
                },
                else => return,
            };
            break;
        }
    }

    fn workerMain(self: *ChunkWorker) void {
        while (true) {
            self.mutex.lock();
            while (self.mesh_job_buffer.isEmpty() and
                self.generation_job_buffer.isEmpty() and
                !self.stopping)
            {
                self.cond.wait(&self.mutex);
            }
            const should_stop = self.stopping;
            self.mutex.unlock();

            if (should_stop) return;

            while (self.generation_job_buffer.pop()) |job| {
                const result = self.terrain_generator.fillChunkVoxels(self.allocator, job) catch |err| {
                    std.log.err("fillChunkVoxels failed for {any}: {s}", .{ job.coord, @errorName(err) });
                    continue;
                };
                self.pushGenerationResultRetry(result);
            }

            while (self.mesh_job_buffer.pop()) |job| {
                const result = mesher.generateMesh(self.allocator, job) catch |err| {
                    std.log.err("generateMesh failed for {any}: {s}", .{ job.coord, @errorName(err) });
                    continue;
                };
                self.pushMeshResultRetry(result);
            }
        }
    }
};
