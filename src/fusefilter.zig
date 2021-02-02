const std = @import("std");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;

// probabillity of success should always be > 0.5 so 100 iterations is highly unlikely
//
// TODO(slimsag): make configurable?
const XOR_MAX_ITERATIONS = 100;

const FUSE_ARITY = 3;
const FUSE_SEGMENT_COUNT = 100;
const FUSE_SLOTS = FUSE_SEGMENT_COUNT + FUSE_ARITY - 1;

/// Dietzfelbinger & Walzer's fuse filters, described in "Dense Peelable Random Uniform Hypergraphs",
/// https://arxiv.org/abs/1907.04749, can accomodate fill factors up to 87.9% full, rather than
/// 1 / 1.23 = 81.3%. In the 8-bit case, this reduces the memory usage from 9.84 bits per entry to
/// 9.1 bits.
///
/// We assume that you have a large set of 64-bit integers and you want a data structure to do
/// membership tests using no more than ~8 or ~16 bits per key. If your initial set is made of
/// strings or other types, you first need to hash them to a 64-bit integer.
/// fuse8 is the recommended default, no more than a 0.3% false-positive probability.
pub const Fuse8 = struct {
    seed: u64,
    segmentLength: u64, // == slotCount / FUSE_SLOTS
    fingerprints: []u8, // has room for 3*segmentLength values

    /// initializes a fuse8 filter with enough capacity for a set containing up to `size` elements.
    ///
    /// `deinit(allocator)` must be called by the caller to free the memory.
    pub fn init(allocator: *Allocator, size: usize) !*Fuse8 {
        const self = try allocator.create(Fuse8);
        var capacity: usize = @floatToInt(usize, 1.0 / 0.879 * @intToFloat(f64, size));
        capacity = capacity / FUSE_SLOTS * FUSE_SLOTS;
        self.* = Fuse8{
            .seed = 0,
            .fingerprints = try allocator.alloc(u8, capacity),
            .segmentLength = capacity / FUSE_SLOTS,
        };
        return self;
    }

    pub fn deinit(self: *Fuse8, allocator: *Allocator) void {
        allocator.destroy(self);
    }

    /// reports if the specified key is within the set with false-positive rate.
    pub inline fn contain(self: *Fuse8, key: u64) bool {
        var hash = util.mix_split(key, self.seed);
        var f = util.fingerprint(hash);
        var r0 = @truncate(u32, hash);
        var r1 = @truncate(u32, util.rotl64(hash, 21));
        var r2 = @truncate(u32, util.rotl64(hash, 42));
        var r3 = @truncate(u32, (0xBF58476D1CE4E5B9 *% hash) >> 32);
        var seg = util.reduce(r0, FUSE_SEGMENT_COUNT);
        var sl = @truncate(u32, self.segmentLength);
        var h0 = (seg + 0) * sl + util.reduce(r1, sl);
        var h1 = (seg + 1) * sl + util.reduce(r2, sl);
        var h2 = (seg + 2) * sl + util.reduce(r3, sl);
        return f == (self.fingerprints[h0] ^ self.fingerprints[h1] ^ self.fingerprints[h2]);
    }

    /// reports the size in bytes of the filter.
    pub inline fn size_in_bytes(self: *Fuse8) usize {
        return FUSE_SLOTS * self.segmentLength * @sizeOf(u8) + @sizeOf(Fuse8);
    }
};

test "fuse8" {
    const allocator = std.heap.page_allocator;
    const size = 1000000;
    const filter = try Fuse8.init(allocator, size);
    defer filter.deinit(allocator);

    testing.expect(filter.contain(1234) == false);
    testing.expectEqual(@as(usize, 1137638), filter.size_in_bytes());
}
