const std = @import("std");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Error = util.Error;

const FUSE_ARITY = 3;
const FUSE_SEGMENT_COUNT = 100;
const FUSE_SLOTS = FUSE_SEGMENT_COUNT + FUSE_ARITY - 1;

/// Fuse8 provides a fuse filter with 8-bit fingerprints.
///
/// See `Fuse` for more details.
pub const Fuse8 = Fuse(u8);

/// DEPRECATED: Consider using binary fuse filters instead, they are less prone to creation failure
/// (i.e. the algorithm works with small sets) and are generally all around better.
///
/// Dietzfelbinger & Walzer's fuse filters, described in "Dense Peelable Random Uniform Hypergraphs",
/// https://arxiv.org/abs/1907.04749, can accomodate fill factors up to 87.9% full, rather than
/// 1 / 1.23 = 81.3%. In the 8-bit case, this reduces the memory usage from 9.84 bits per entry to
/// 9.1 bits.
///
/// We assume that you have a large set of 64-bit integers and you want a data structure to do
/// membership tests using no more than ~8 or ~16 bits per key. If your initial set is made of
/// strings or other types, you first need to hash them to a 64-bit integer.
pub fn Fuse(comptime T: type) type {
    return struct {
        seed: u64,
        segmentLength: u64, // == slotCount / FUSE_SLOTS
        fingerprints: []T, // has room for 3*segmentLength values

        /// probability of success should always be > 0.5 so 100 iterations is highly unlikely
        max_iterations: usize = 100,

        const Self = @This();

        /// initializes a fuse filter with enough capacity for a set containing up to `size` elements.
        ///
        /// `deinit()` must be called by the caller to free the memory.
        pub fn init(allocator: Allocator, size: usize) !Self {
            var capacity = @as(usize, @intFromFloat((1.0 / 0.879) * @as(f64, @floatFromInt(size))));
            capacity = capacity / FUSE_SLOTS * FUSE_SLOTS;
            return Self{
                .seed = 0,
                .fingerprints = try allocator.alloc(T, capacity),
                .segmentLength = capacity / FUSE_SLOTS,
            };
        }

        pub inline fn deinit(self: *const Self, allocator: Allocator) void {
            allocator.free(self.fingerprints);
        }

        /// reports if the specified key is within the set with false-positive rate.
        pub inline fn contain(self: *const Self, key: u64) bool {
            const hash = util.mixSplit(key, self.seed);
            const f = @as(T, @truncate(util.fingerprint(hash)));
            const r0 = @as(u32, @truncate(hash));
            const r1 = @as(u32, @truncate(util.rotl64(hash, 21)));
            const r2 = @as(u32, @truncate(util.rotl64(hash, 42)));
            const r3 = @as(u32, @truncate((0xBF58476D1CE4E5B9 *% hash) >> 32));
            const seg = util.reduce(r0, FUSE_SEGMENT_COUNT);
            const sl: u64 = self.segmentLength;
            const h0 = (seg + 0) * sl + util.reduce(r1, @as(u32, @truncate(sl)));
            const h1 = (seg + 1) * sl + util.reduce(r2, @as(u32, @truncate(sl)));
            const h2 = (seg + 2) * sl + util.reduce(r3, @as(u32, @truncate(sl)));
            return f == (self.fingerprints[h0] ^ self.fingerprints[h1] ^ self.fingerprints[h2]);
        }

        /// reports the size in bytes of the filter.
        pub inline fn sizeInBytes(self: *const Self) usize {
            return FUSE_SLOTS * self.segmentLength * @sizeOf(T) + @sizeOf(Self);
        }

        /// populates the filter with the given keys.
        ///
        /// The caller is responsible for ensuring that there are no duplicated keys.
        ///
        /// The inner loop will run up to max_iterations times (default 100) and will never fail,
        /// except if there are duplicated keys.
        ///
        /// The provided allocator will be used for creating temporary buffers that do not outlive the
        /// function call.
        pub fn populate(self: *Self, allocator: Allocator, keys: []u64) Error!void {
            var iter = util.SliceIterator(u64).init(keys);
            return self.populateIter(allocator, &iter);
        }

        /// Identical to populate, except it takes an iterator of keys so you need not store them
        /// in-memory.
        ///
        /// `keys.next()` must return `?u64`, the next key or none if the end of the list has been
        /// reached. The iterator must reset after hitting the end of the list, such that the `next()`
        /// call leads to the first element again.
        ///
        /// `keys.len()` must return the `usize` length.
        pub fn populateIter(self: *Self, allocator: Allocator, keys: anytype) Error!void {
            var rng_counter: u64 = 1;
            self.seed = util.rngSplitMix64(&rng_counter);

            var sets = try allocator.alloc(Set, self.segmentLength * FUSE_SLOTS);
            defer allocator.free(sets);

            var Q = try allocator.alloc(Keyindex, sets.len);
            defer allocator.free(Q);

            var stack = try allocator.alloc(Keyindex, keys.len());
            defer allocator.free(stack);

            var loop: usize = 0;
            while (true) : (loop += 1) {
                if (loop + 1 > self.max_iterations) {
                    return Error.KeysLikelyNotUnique; // too many iterations, keys are not unique.
                }
                for (sets[0..sets.len]) |*b| b.* = std.mem.zeroes(Set);

                while (keys.next()) |key| {
                    const hs = getH0H1H2(self, key);
                    sets[hs.h0].fusemask ^= hs.h;
                    sets[hs.h0].count += 1;
                    sets[hs.h1].fusemask ^= hs.h;
                    sets[hs.h1].count += 1;
                    sets[hs.h2].fusemask ^= hs.h;
                    sets[hs.h2].count += 1;
                }

                // TODO(upstream): the flush should be sync with the detection that follows scan values
                // with a count of one.
                var Qsize: usize = 0;
                for (sets, 0..) |set, i| {
                    if (set.count == 1) {
                        Q[Qsize].index = @as(u32, @intCast(i));
                        Q[Qsize].hash = sets[i].fusemask;
                        Qsize += 1;
                    }
                }

                var stack_size: usize = 0;
                while (Qsize > 0) {
                    Qsize -= 1;
                    const keyindex = Q[Qsize];
                    const index = keyindex.index;
                    if (sets[index].count == 0) {
                        continue; // not actually possible after the initial scan.
                    }
                    const hash = keyindex.hash;
                    const hs = getJustH0H1H2(self, hash);

                    stack[stack_size] = keyindex;
                    stack_size += 1;

                    sets[hs.h0].fusemask ^= hash;
                    sets[hs.h0].count -= 1;
                    if (sets[hs.h0].count == 1) {
                        Q[Qsize].index = hs.h0;
                        Q[Qsize].hash = sets[hs.h0].fusemask;
                        Qsize += 1;
                    }

                    sets[hs.h1].fusemask ^= hash;
                    sets[hs.h1].count -= 1;
                    if (sets[hs.h1].count == 1) {
                        Q[Qsize].index = hs.h1;
                        Q[Qsize].hash = sets[hs.h1].fusemask;
                        Qsize += 1;
                    }

                    sets[hs.h2].fusemask ^= hash;
                    sets[hs.h2].count -= 1;
                    if (sets[hs.h2].count == 1) {
                        Q[Qsize].index = hs.h2;
                        Q[Qsize].hash = sets[hs.h2].fusemask;
                        Qsize += 1;
                    }
                }
                if (stack_size == keys.len()) {
                    // success
                    break;
                }
                self.seed = util.rngSplitMix64(&rng_counter);
            }

            var stack_size = keys.len();
            while (stack_size > 0) {
                stack_size -= 1;
                const ki = stack[stack_size];
                const hs = getJustH0H1H2(self, ki.hash);
                var hsh: T = @as(T, @truncate(util.fingerprint(ki.hash)));
                if (ki.index == hs.h0) {
                    hsh ^= self.fingerprints[hs.h1] ^ self.fingerprints[hs.h2];
                } else if (ki.index == hs.h1) {
                    hsh ^= self.fingerprints[hs.h0] ^ self.fingerprints[hs.h2];
                } else {
                    hsh ^= self.fingerprints[hs.h0] ^ self.fingerprints[hs.h1];
                }
                self.fingerprints[ki.index] = hsh;
            }
            return;
        }

        inline fn getH0H1H2(self: *Self, k: u64) Hashes {
            const hash = util.mixSplit(k, self.seed);
            const r0 = @as(u32, @truncate(hash));
            const r1 = @as(u32, @truncate(util.rotl64(hash, 21)));
            const r2 = @as(u32, @truncate(util.rotl64(hash, 42)));
            const r3 = @as(u32, @truncate((0xBF58476D1CE4E5B9 *% hash) >> 32));
            const seg = util.reduce(r0, FUSE_SEGMENT_COUNT);
            const sl = self.segmentLength;
            return Hashes{
                .h = hash,
                .h0 = @as(u32, @truncate(@as(u64, @intCast((seg + 0))) * sl + @as(u64, @intCast(util.reduce(r1, @as(u32, @truncate(sl))))))),
                .h1 = @as(u32, @truncate(@as(u64, @intCast((seg + 1))) * sl + @as(u64, @intCast(util.reduce(r2, @as(u32, @truncate(sl))))))),
                .h2 = @as(u32, @truncate(@as(u64, @intCast((seg + 2))) * sl + @as(u64, @intCast(util.reduce(r3, @as(u32, @truncate(sl))))))),
            };
        }

        inline fn getJustH0H1H2(self: *Self, hash: u64) H0h1h2 {
            const r0 = @as(u32, @truncate(hash));
            const r1 = @as(u32, @truncate(util.rotl64(hash, 21)));
            const r2 = @as(u32, @truncate(util.rotl64(hash, 42)));
            const r3 = @as(u32, @truncate((0xBF58476D1CE4E5B9 *% hash) >> 32));
            const seg = util.reduce(r0, FUSE_SEGMENT_COUNT);
            const sl = self.segmentLength;
            return H0h1h2{
                .h0 = @as(u32, @truncate(@as(u64, @intCast((seg + 0))) * sl + @as(u64, @intCast(util.reduce(r1, @as(u32, @truncate(sl))))))),
                .h1 = @as(u32, @truncate(@as(u64, @intCast((seg + 1))) * sl + @as(u64, @intCast(util.reduce(r2, @as(u32, @truncate(sl))))))),
                .h2 = @as(u32, @truncate(@as(u64, @intCast((seg + 2))) * sl + @as(u64, @intCast(util.reduce(r3, @as(u32, @truncate(sl))))))),
            };
        }
    };
}

const Set = struct {
    fusemask: u64,
    count: u32,
};

const Hashes = struct {
    h: u64,
    h0: u32,
    h1: u32,
    h2: u32,
};

const H0h1h2 = struct {
    h0: u32,
    h1: u32,
    h2: u32,
};

const Keyindex = struct {
    hash: u64,
    index: u32,
};

fn fuseTest(T: anytype, size: usize, size_in_bytes: usize) !void {
    const allocator = std.heap.page_allocator;
    var filter = try Fuse(T).init(allocator, size);
    defer filter.deinit(allocator);

    var keys = try allocator.alloc(u64, size);
    defer allocator.free(keys);
    for (keys, 0..) |_, i| {
        keys[i] = i;
    }

    try filter.populate(allocator, keys[0..]);

    try testing.expect(filter.contain(1) == true);
    try testing.expect(filter.contain(5) == true);
    try testing.expect(filter.contain(9) == true);
    try testing.expect(filter.contain(1234) == true);
    try testing.expectEqual(@as(usize, size_in_bytes), filter.sizeInBytes());

    for (keys) |key| {
        try testing.expect(filter.contain(key) == true);
    }

    var random_matches: u64 = 0;
    const trials = 10000000;
    var i: u64 = 0;
    var rng = std.Random.DefaultPrng.init(0);
    const random = rng.random();
    while (i < trials) : (i += 1) {
        const random_key: u64 = random.uintAtMost(u64, std.math.maxInt(u64));
        if (filter.contain(random_key)) {
            if (random_key >= keys.len) {
                random_matches += 1;
            }
        }
    }

    // std.debug.print("fpp {d:3.10} (estimated) \n", .{@floatFromInt(f64, random_matches) * 1.0 / trials});
    // std.debug.print("bits per entry {d:3.1}\n", .{@floatFromInt(f64, filter.sizeInBytes()) * 8.0 / @floatFromInt(f64, size)});
}

test "fuse4" {
    try fuseTest(u4, 1000000 / 2, 568792);
}

test "fuse8" {
    try fuseTest(u8, 1000000, 1137646);
}

test "fuse16" {
    try fuseTest(u16, 1000000, 2275252);
}
