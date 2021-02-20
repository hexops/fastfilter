const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const Error = error{
    KeysLikelyNotUnique,
    OutOfMemory,
};

pub fn murmur64(h: u64) callconv(.Inline) u64 {
    var v = h;
    v ^= v >> 33;
    v *%= 0xff51afd7ed558ccd;
    v ^= v >> 33;
    v *%= 0xc4ceb9fe1a85ec53;
    v ^= v >> 33;
    return v;
}

pub fn mixSplit(key: u64, seed: u64) callconv(.Inline) u64 {
    return murmur64(key +% seed);
}

pub fn rotl64(n: u64, c: usize) callconv(.Inline) u64 {
    return (n << @intCast(u6, c & 63)) | (n >> @intCast(u6, (-%c) & 63));
}

pub fn reduce(hash: u32, n: u32) callconv(.Inline) u32 {
    // http://lemire.me/blog/2016/06/27/a-fast-alternative-to-the-modulo-reduction
    return @truncate(u32, (@intCast(u64, hash) *% @intCast(u64, n)) >> 32);
}

pub fn fingerprint(hash: u64) callconv(.Inline) u64 {
    return hash ^ (hash >> 32);
}

pub fn sliceIterator(comptime T: type) type {
    return struct {
        allocator: *Allocator,
        slice: []T,
        i: usize,

        const Self = @This();

        pub fn init(allocator: *Allocator, slice: []T) callconv(.Inline) !*Self {
            const self = try allocator.create(Self);
            self.* = Self{
                .allocator = allocator,
                .i = 0,
                .slice = slice,
            };
            return self;
        }

        pub fn deinit(self: *Self) callconv(.Inline) void {
            self.allocator.destroy(self);
        }

        pub fn next(self: *Self) callconv(.Inline) ?T {
            if (self.i >= self.slice.len) {
                self.i = 0;
                return null;
            }
            const v = self.slice[self.i];
            self.i += 1;
            return v;
        }

        pub fn len(self: *Self) callconv(.Inline) usize {
            return self.slice.len;
        }
    };
}

// returns random number, modifies the seed.
pub fn rngSplitMix64(seed: *u64) callconv(.Inline) u64 {
    seed.* = seed.* +% 0x9E3779B97F4A7C15;
    var z = seed.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

test "murmur64" {
    // Arbitrarily chosen inputs for validation.
    testing.expectEqual(@as(u64, 11156705658460211942), murmur64(0xF + 5));
    testing.expectEqual(@as(u64, 9276143743022464963), murmur64(0xFF + 123));
    testing.expectEqual(@as(u64, 9951468085874665196), murmur64(0xFFF + 1337));
    testing.expectEqual(@as(u64, 4797998644499646477), murmur64(0xFFFF + 143));
    testing.expectEqual(@as(u64, 4139256335519489731), murmur64(0xFFFFFF + 918273987));
}

test "mixSplit" {
    // Arbitrarily chosen inputs for validation.
    testing.expectEqual(@as(u64, 11156705658460211942), mixSplit(0xF, 5));
}

test "rotl64" {
    // Arbitrarily chosen inputs for validation.
    testing.expectEqual(@as(u64, 193654783976931328), rotl64(43, 52));
}

test "reduce" {
    // Arbitrarily chosen inputs for validation.
    testing.expectEqual(@as(u32, 8752776), reduce(1936547838, 19412321));
}

test "fingerprint" {
    // Arbitrarily chosen inputs for validation.
    testing.expectEqual(@as(u64, 1936547838), fingerprint(1936547838));
}

test "rngSplitMix64" {
    var seed: u64 = 13337;
    var r = rngSplitMix64(&seed);
    testing.expectEqual(@as(u64, 8862613829200693549), r);
    r = rngSplitMix64(&seed);
    testing.expectEqual(@as(u64, 1009918040199880802), r);
    r = rngSplitMix64(&seed);
    testing.expectEqual(@as(u64, 8603670078971061766), r);
}
