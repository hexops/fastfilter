/// This allocator takes an existing allocator, wraps it, and provides measurements about the
/// allocations such as peak memory usage.
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const MeasuredAllocator = @This();

allocator: Allocator,

child_allocator: Allocator,
state: State,

/// Inner state of MeasuredAllocator. Can be stored rather than the entire MeasuredAllocator as a
/// memory-saving optimization.
pub const State = struct {
    peak_memory_usage_bytes: usize = 0,
    current_memory_usage_bytes: usize = 0,

    pub fn promote(self: State, child_allocator: Allocator) MeasuredAllocator {
        return .{
            .allocator = Allocator{
                .allocFn = alloc,
                .resizeFn = resize,
            },
            .child_allocator = child_allocator,
            .state = self,
        };
    }
};

const BufNode = std.SinglyLinkedList([]u8).Node;

pub fn init(child_allocator: Allocator) MeasuredAllocator {
    return (State{}).promote(child_allocator);
}

fn alloc(allocator: Allocator, n: usize, ptr_align: u29, len_align: u29, ra: usize) ![]u8 {
    const self = @fieldParentPtr(MeasuredAllocator, "allocator", allocator);
    const m = try self.child_allocator.allocFn(self.child_allocator, n, ptr_align, len_align, ra);
    self.state.current_memory_usage_bytes += n;
    if (self.state.current_memory_usage_bytes > self.state.peak_memory_usage_bytes) self.state.peak_memory_usage_bytes = self.state.current_memory_usage_bytes;
    return m;
}

fn resize(allocator: Allocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ret_addr: usize) Allocator.Error!usize {
    const self = @fieldParentPtr(MeasuredAllocator, "allocator", allocator);
    const final_len = try self.child_allocator.resizeFn(self.child_allocator, buf, buf_align, new_len, len_align, ret_addr);
    self.state.current_memory_usage_bytes -= buf.len - new_len;
    if (self.state.current_memory_usage_bytes > self.state.peak_memory_usage_bytes) self.state.peak_memory_usage_bytes = self.state.current_memory_usage_bytes;
    return final_len;
}
