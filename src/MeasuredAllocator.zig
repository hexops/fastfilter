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
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = allocFn,
            .resize = resizeFn,
            .free = freeFn,
            .remap = remapFn,
        },
    };
}

fn remapFn(ptr: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self = @as(*MeasuredAllocator, @ptrCast(@alignCast(ptr)));
    return self.parent_allocator.rawRemap(memory, alignment, new_len, ret_addr);
}

fn allocFn(ptr: *anyopaque, len: usize, ptr_align: mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self = @as(*MeasuredAllocator, @ptrCast(@alignCast(ptr)));
    const result = self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
    if (result) |_| {
        self.state.current_memory_usage_bytes += len;
        if (self.state.current_memory_usage_bytes > self.state.peak_memory_usage_bytes) self.state.peak_memory_usage_bytes = self.state.current_memory_usage_bytes;
    }
    return result;
}

fn resizeFn(ptr: *anyopaque, buf: []u8, buf_align: mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self = @as(*MeasuredAllocator, @ptrCast(@alignCast(ptr)));
    if (self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr)) {
        self.state.current_memory_usage_bytes -= buf.len - new_len;
        if (self.state.current_memory_usage_bytes > self.state.peak_memory_usage_bytes) self.state.peak_memory_usage_bytes = self.state.current_memory_usage_bytes;
        return true;
    }
    return false;
}

fn freeFn(ptr: *anyopaque, buf: []u8, buf_align: mem.Alignment, ret_addr: usize) void {
    const self = @as(*MeasuredAllocator, @ptrCast(@alignCast(ptr)));
    self.parent_allocator.rawFree(buf, buf_align, ret_addr);
    self.state.current_memory_usage_bytes -= buf.len;
}
