const std = @import("std");
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
};

test "fuse8" {
    const allocator = std.heap.page_allocator;
    const size = 1000000;
    const filter = try Fuse8.init(allocator, size);
    defer filter.deinit(allocator);
}
