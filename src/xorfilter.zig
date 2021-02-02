const std = @import("std");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;

// probabillity of success should always be > 0.5 so 100 iterations is highly unlikely
//
// TODO(slimsag): make configurable?
const XOR_MAX_ITERATIONS = 100;

/// Xor8 is the recommended default, no more than a 0.3% false-positive probability.
///
/// See `Xor` for more details.
pub const Xor8 = Xor(u8);

/// Xor16 provides a xor filter with 16-bit fingerprints.
///
/// See `Xor` for more details.
pub const Xor16 = Xor(u16);

/// Xor returns a xor filter with the specified base type, usually u8 or u16, for which the
/// helpers Xor8 and Xor16 may be used.
///
/// We assume that you have a large set of 64-bit integers and you want a data structure to do
/// membership tests using no more than ~8 or ~16 bits per key. If your initial set is made of
/// strings or other types, you first need to hash them to a 64-bit integer.
///
/// Xor8 is the recommended default, no more than a 0.3% false-positive probability.
pub fn Xor(comptime T: type) type {
    return struct {
        seed: u64,
        blockLength: u64,
        fingerprints: []T, // has room for 3*blockLength values

        const Self = @This();

        /// initializes a Xor filter with enough capacity for a set containing up to `size` elements.
        ///
        /// `deinit(allocator)` must be called by the caller to free the memory.
        pub fn init(allocator: *Allocator, size: usize) !*Self {
            const self = try allocator.create(Self);
            var capacity = @floatToInt(usize, 32 + 1.23 + @intToFloat(f64, size));
            capacity = capacity / 3 * 3;
            self.* = Self{
                .seed = 0,
                .fingerprints = try allocator.alloc(T, capacity),
                .blockLength = capacity / 3,
            };
            return self;
        }

        pub inline fn deinit(self: *Self, allocator: *Allocator) void {
            allocator.destroy(self);
        }

        /// reports if the specified key is within the set with false-positive rate.
        pub inline fn contain(self: *Self, key: u64) bool {
            var hash = util.mix_split(key, self.seed);
            var f = util.fingerprint(hash);
            var r0 = @truncate(u32, hash);
            var r1 = @truncate(u32, util.rotl64(hash, 21));
            var r2 = @truncate(u32, util.rotl64(hash, 42));
            var bl = @truncate(u32, self.blockLength);
            var h0 = util.reduce(r0, bl);
            var h1 = util.reduce(r1, bl) + bl;
            var h2 = util.reduce(r2, bl) + 2 * bl;
            return f == (self.fingerprints[h0] ^ self.fingerprints[h1] ^ self.fingerprints[h2]);
        }

        /// reports the size in bytes of the filter.
        pub inline fn size_in_bytes(self: *Self) usize {
            return 3 * self.blockLength * @sizeOf(T) + @sizeOf(Self);
        }
    };
}

test "xor8" {
    const allocator = std.heap.page_allocator;
    const size = 1000000;
    const filter = try Xor8.init(allocator, size);
    defer filter.deinit(allocator);

    testing.expect(filter.contain(1234) == false);
    testing.expectEqual(@as(usize, 1000064), filter.size_in_bytes());
}

test "xor16" {
    const allocator = std.heap.page_allocator;
    const size = 1000000;
    const filter = try Xor16.init(allocator, size);
    defer filter.deinit(allocator);

    testing.expect(filter.contain(1234) == false);
    testing.expectEqual(@as(usize, 2000096), filter.size_in_bytes());
}
