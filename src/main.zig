const std = @import("std");

pub const BinaryFuse = @import("binaryfusefilter.zig").BinaryFuse;
pub const BinaryFuse8 = @import("binaryfusefilter.zig").BinaryFuse8;
pub const Xor = @import("xorfilter.zig").Xor;
pub const Xor8 = @import("xorfilter.zig").Xor8;
pub const Xor16 = @import("xorfilter.zig").Xor16;
pub const AutoUnique = @import("unique.zig").AutoUnique;
pub const Unique = @import("unique.zig").Unique;
pub const Error = @import("util.zig").Error;
pub const SliceIterator = @import("util.zig").SliceIterator;

test "exports" {
    const allocator = std.heap.page_allocator;

    var binaryFuse8Filter = try BinaryFuse8.init(allocator, 100);
    defer binaryFuse8Filter.deinit(allocator);

    var xorFilter = try Xor(u8).init(allocator, 1);
    defer xorFilter.deinit(allocator);

    var xor8Filter = try Xor8.init(allocator, 1);
    defer xor8Filter.deinit(allocator);

    var xor16Filter = try Xor16.init(allocator, 1);
    defer xor16Filter.deinit(allocator);

    var array = [_]i32{ 1, 2, 2 };
    _ = AutoUnique(i32, void)({}, array[0..]);

    _ = SliceIterator;

    _ = @import("fusefilter.zig");
}
