//! Single producer, single consumer ring buffer
//!
//! Concurrency problem:
//! Suppose the producer writes `item` into buf[tail], and update tail.
//! And suppose the consumer reads `tail`; if queue not empty, read `buf[head]`
//!
//! We want to guarantee that if the consumer sees the new `tail`, then the
//! item in buf[tail_old] must already be fully written.
//!
//! Even though only one thread writes each index:
//! - the producer reads `head`
//! - the consumer reads `tail`
//! So each side is reading data that another thread writes.
//! That shared communication must be atomic and ordered properly.
//!
//! The two variables are acting like signals:
//! - `tail` is the producer's "I have published more data" signal
//! - `head` is the consumer's "I have finished consuming data" signal
//!
//! Because only one thread writes each variable, the code does not need
//! compare-and-swap or mutexes.

const std = @import("std");
const AtomicOrder = std.builtin.AtomicOrder;

/// Single producer, single consumer ring buffer
pub fn SpscRingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: []T,
        head: usize = 0, // consumer-owned
        tail: usize = 0, // producer-owned

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            // One slot is intentionally unused, so usable capacity is capacity - 1.
            if (capacity < 2) return error.InvalidCapacity;
            return .{
                .buf = try allocator.alloc(T, capacity),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buf);
            self.* = undefined;
        }

        inline fn next(self: *const Self, i: usize) usize {
            return if (i + 1 == self.buf.len) 0 else i + 1;
        }

        pub inline fn usableCapacity(self: *const Self) usize {
            return self.buf.len - 1;
        }

        // Producer thread only.
        pub fn push(self: *Self, item: T) !void {
            // The producer is reading its own `tail`.
            // Atomic only for consistency and corectness of shared access rules.
            const tail = @atomicLoad(usize, &self.tail, .monotonic);
            const next_tail = self.next(tail);

            // `head` is written by the consumer. The producer needs to know
            // whether the queue is full. To know that, it must see the
            // consumer's latest `head`.
            // Why `.acquire`? Because the consumer updates `head` with
            // `.release` after finishing a `pop`.
            // "Read the consumer's position, and if I see its latest published
            // value, also see everything that happened before that publication."
            const head = @atomicLoad(usize, &self.head, .acquire);
            if (next_tail == head) return error.Full;

            self.buf[tail] = item;

            // "I have finished writing the item. Now I publish the new tail."
            // The `.release means`:
            // all earlier writes by this thread, including `self.buf[tail] = item`
            // must become visible before the new `tail` becomes visible to
            // another thread doing an acquire load.
            @atomicStore(usize, &self.tail, next_tail, .release);
        }

        // Consumer thread only.
        pub fn pop(self: *Self) ?T {
            const head = @atomicLoad(usize, &self.head, .monotonic);

            const tail = @atomicLoad(usize, &self.tail, .acquire);
            if (head == tail) return null;

            const item = self.buf[head];
            const next_head = self.next(head);

            @atomicStore(usize, &self.head, next_head, .release);
            return item;
        }

        pub fn isEmpty(self: *Self) bool {
            const head = @atomicLoad(usize, &self.head, .acquire);
            const tail = @atomicLoad(usize, &self.tail, .acquire);
            return head == tail;
        }
    };
}
