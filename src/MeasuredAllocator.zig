/// This allocator takes an existing allocator, wraps it, and provides measurements about the
/// allocations such as peak memory usage.
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const MeasuredAllocator = @This();

parent_allocator: Allocator,
state: State,

/// Inner state of MeasuredAllocator. Can be stored rather than the entire MeasuredAllocator as a
/// memory-saving optimization.
pub const State = struct {
    peak_memory_usage_bytes: usize = 0,
    current_memory_usage_bytes: usize = 0,

    pub fn promote(self: State, parent_allocator: Allocator) MeasuredAllocator {
        return .{
            .parent_allocator = parent_allocator,
            .state = self,
        };
    }
};

const BufNode = std.SinglyLinkedList([]u8).Node;

pub fn init(parent_allocator: Allocator) MeasuredAllocator {
    return (State{}).promote(parent_allocator);
}

pub fn allocator(self: *MeasuredAllocator) Allocator {
    return Allocator.init(self, alloc, resize, free);
}

fn alloc(self: *MeasuredAllocator, len: usize, ptr_align: u29, len_align: u29, ra: usize) error{OutOfMemory}![]u8 {
    const result = self.parent_allocator.rawAlloc(len, ptr_align, len_align, ra);
    if (result) |_| {
        self.state.current_memory_usage_bytes += len;
        if (self.state.current_memory_usage_bytes > self.state.peak_memory_usage_bytes) self.state.peak_memory_usage_bytes = self.state.current_memory_usage_bytes;
    } else |_| {}
    return result;
}

fn resize(self: *MeasuredAllocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ra: usize) ?usize {
    if (self.parent_allocator.rawResize(buf, buf_align, new_len, len_align, ra)) |resized_len| {
        self.state.current_memory_usage_bytes -= buf.len - new_len;
        if (self.state.current_memory_usage_bytes > self.state.peak_memory_usage_bytes) self.state.peak_memory_usage_bytes = self.state.current_memory_usage_bytes;
        return resized_len;
    }
    std.debug.assert(new_len > buf.len);
    return null;
}

fn free(self: *MeasuredAllocator, buf: []u8, buf_align: u29, ra: usize) void {
    self.parent_allocator.rawFree(buf, buf_align, ra);
    self.state.current_memory_usage_bytes -= buf.len;
}
