//! This ring buffer stores read and write indices while being able to utilise
//! the full backing slice by incrementing the indices modulo twice the slice's
//! length and reducing indices modulo the slice's length on slice access. This
//! means that whether the ring buffer is full or empty can be distinguished by
//! looking at the difference between the read and write indices without adding
//! an extra boolean flag or having to reserve a slot in the buffer.
//!
//! This ring buffer has not been implemented with thread safety in mind, and
//! therefore should not be assumed to be suitable for use cases involving
//! separate reader and writer threads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub fn RingBufferConstructor(comptime T: type) type {
    return struct {
        const RingBuffer = @This();

        data: []T,
        read_index: usize,
        write_index: usize,
        mutex: std.Thread.Mutex,

        pub const Error = error{ Full, ReadLengthInvalid };

        /// Allocate a new `RingBuffer`; `deinit()` should be called to free the buffer.
        pub fn create(allocator: Allocator, capacity: usize) Allocator.Error!*RingBuffer {
            const bytes = try allocator.alloc(T, capacity);
            const rb =  try allocator.create(RingBuffer);
            rb.data = bytes;
            rb.write_index = 0;
            rb.read_index = 0;
            rb.mutex = .{};
            return rb;
        }

        /// Free the data backing a `RingBuffer`; must be passed the same `Allocator` as
        /// `init()`.
        pub fn deinit(self: *RingBuffer, allocator: Allocator) void {
            allocator.free(self.data);
            allocator.destroy(self);
        }

        /// Returns `index` modulo the length of the backing slice.
        pub fn mask(self: RingBuffer, index: usize) usize {
            return index % self.data.len;
        }

        /// Returns `index` modulo twice the length of the backing slice.
        pub fn mask2(self: RingBuffer, index: usize) usize {
            return index % (2 * self.data.len);
        }

        /// Write `byte` into the ring buffer. Returns `error.Full` if the ring
        /// buffer is full.
        pub fn write(self: *RingBuffer, byte: T) Error!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.isFull()) return error.Full;
            self.writeAssumeCapacity(byte);
        }

        /// Write `byte` into the ring buffer. If the ring buffer is full, the
        /// oldest byte is overwritten.
        pub fn writeAssumeCapacity(self: *RingBuffer, byte: T) void {
            self.data[self.mask(self.write_index)] = byte;
            self.write_index = self.mask2(self.write_index + 1);
        }




        /// Consume a byte from the ring buffer and return it. Returns `null` if the
        /// ring buffer is empty.
        pub fn read(self: *RingBuffer) ?T {
            if (self.isEmpty()) return null;
            return self.readAssumeLength();
        }


        /// Consume a byte from the ring buffer and return it; asserts that the buffer
        /// is not empty.
        pub fn readAssumeLength(self: *RingBuffer) T {
            self.mutex.lock();
            defer self.mutex.unlock();
            assert(!self.isEmpty());
            const byte = self.data[self.mask(self.read_index)];
            self.read_index = self.mask2(self.read_index + 1);
            return byte;
        }

        pub fn peek(self: *RingBuffer) ?T {
            if (self.isEmpty()) return null;
            return self.peekAssumeLength();
        }

        pub fn peekAssumeLength(self: *RingBuffer) T {
            assert(!self.isEmpty());
            const byte = self.data[self.mask(self.read_index)];
            return byte;
        }

        /// Returns `true` if the ring buffer is empty and `false` otherwise.
        pub fn isEmpty(self: RingBuffer) bool {
            return self.write_index == self.read_index;
        }

        /// Returns `true` if the ring buffer is full and `false` otherwise.
        pub fn isFull(self: RingBuffer) bool {
            return self.mask2(self.write_index + self.data.len) == self.read_index;
        }

        /// Returns the length
        pub fn len(self: RingBuffer) usize {
            const wrap_offset = 2 * self.data.len * @intFromBool(self.write_index < self.read_index);
            const adjusted_write_index = self.write_index + wrap_offset;
            return adjusted_write_index - self.read_index;
        }
    };
}
