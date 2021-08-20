const std = @import("std");

pub const Fuse = @import("fusefilter.zig").Fuse;
pub const Fuse8 = @import("fusefilter.zig").Fuse8;
pub const BinaryFuse = @import("binaryfusefilter.zig").BinaryFuse;
pub const BinaryFuse8 = @import("binaryfusefilter.zig").BinaryFuse8;
pub const Xor = @import("xorfilter.zig").Xor;
pub const Xor8 = @import("xorfilter.zig").Xor8;
pub const Xor16 = @import("xorfilter.zig").Xor16;
pub const AutoUnique = @import("unique.zig").AutoUnique;
pub const Unique = @import("unique.zig").Unique;
pub const Error = @import("util.zig").Error;

test "exports" {
    const allocator = std.heap.page_allocator;

    const fuse8Filter = try Fuse8.init(allocator, 1);
    defer fuse8Filter.deinit();

    const binaryFuse8Filter = try BinaryFuse8.init(allocator, 100);
    defer binaryFuse8Filter.deinit();

    const xorFilter = try Xor(u8).init(allocator, 1);
    defer xorFilter.deinit();

    const xor8Filter = try Xor8.init(allocator, 1);
    defer xor8Filter.deinit();

    const xor16Filter = try Xor16.init(allocator, 1);
    defer xor16Filter.deinit();

    var array = [_]i32{ 1, 2, 2 };
    _ = AutoUnique(i32, void)({}, array[0..]);
}
