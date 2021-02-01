const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

// probabillity of success should always be > 0.5 so 100 iterations is highly unlikely
//
// TODO(slimsag): make configurable?
const XOR_MAX_ITERATIONS = 100;

/// Xor8 is the recommended default, no more than a 0.3% false-positive probability.
///
/// See `Xor` for more details.
const Xor8 = Xor(u8);

/// Xor16 provides a xor filter with 16-bit fingerprints.
///
/// See `Xor` for more details.
const Xor16 = Xor(u16);

/// Xor returns a xor filter with the specified base type, usually u8 or u16, for which the
/// helpers Xor8 and Xor16 may be used.
///
/// We assume that you have a large set of 64-bit integers and you want a data structure to do
/// membership tests using no more than ~8 or ~16 bits per key. If your initial set is made of
/// strings or other types, you first need to hash them to a 64-bit integer.
///
/// Xor8 is the recommended default, no more than a 0.3% false-positive probability.
fn Xor(comptime T: type) type {
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

        pub fn deinit(self: *Self, allocator: *Allocator) void {
            allocator.destroy(self);
        }
    };
}

test "xor8" {
    const allocator = std.heap.page_allocator;
    const size = 1000000;
    const filter = try Xor8.init(allocator, size);
    defer filter.deinit(allocator);
}

test "xor16" {
    const allocator = std.heap.page_allocator;
    const size = 1000000;
    const filter = try Xor16.init(allocator, size);
    defer filter.deinit(allocator);
}
