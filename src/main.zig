const std = @import("std");

pub const Fuse8 = @import("fusefilter.zig").Fuse8;
pub const Xor = @import("xorfilter.zig").Xor;
pub const Xor8 = @import("xorfilter.zig").Xor8;
pub const Xor16 = @import("xorfilter.zig").Xor16;

test "exports" {
    const allocator = std.heap.page_allocator;

    const fuse8Filter = try Fuse8.init(allocator, 1);
    defer fuse8Filter.deinit(allocator);

    const xorFilter = try Xor(u8).init(allocator, 1);
    defer xorFilter.deinit(allocator);

    const xor8Filter = try Xor8.init(allocator, 1);
    defer xor8Filter.deinit(allocator);

    const xor16Filter = try Xor16.init(allocator, 1);
    defer xor16Filter.deinit(allocator);
}
