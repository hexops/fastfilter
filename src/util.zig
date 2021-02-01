const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

pub fn murmur64(h: u64) u64 {
    var v = h;
    v ^= v >> 33;
    v *%= 0xff51afd7ed558ccd;
    v ^= v >> 33;
    v *%= 0xc4ceb9fe1a85ec53;
    v ^= v >> 33;
    return v;
}

test "murmur64" {
    // Arbitrarily chosen inputs for validation.
    testing.expectEqual(@as(u64, 11156705658460211942), murmur64(0xF+5));
    testing.expectEqual(@as(u64, 9276143743022464963), murmur64(0xFF+123));
    testing.expectEqual(@as(u64, 9951468085874665196), murmur64(0xFFF+1337));
    testing.expectEqual(@as(u64, 4797998644499646477), murmur64(0xFFFF+143));
    testing.expectEqual(@as(u64, 4139256335519489731), murmur64(0xFFFFFF+918273987));
}
