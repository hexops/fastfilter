const std = @import("std");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const FUSE_ARITY = 3;
const FUSE_SEGMENT_COUNT = 100;
const FUSE_SLOTS = FUSE_SEGMENT_COUNT + FUSE_ARITY - 1;

/// Fuse8 provides a fuse filter with 8-bit fingerprints.
///
/// See `Fuse` for more details.
pub const Fuse8 = Fuse(u8);

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

        /// probabillity of success should always be > 0.5 so 100 iterations is highly unlikely
        maxIterations: comptime usize = 100,

        const Self = @This();

        /// initializes a fuse filter with enough capacity for a set containing up to `size` elements.
        ///
        /// `deinit(allocator)` must be called by the caller to free the memory.
        pub fn init(allocator: *Allocator, size: usize) !*Self {
            const self = try allocator.create(Self);
            var capacity = @floatToInt(usize, (1.0 / 0.879) * @intToFloat(f64, size));
            capacity = capacity / FUSE_SLOTS * FUSE_SLOTS;
            self.* = Self{
                .seed = 0,
                .fingerprints = try allocator.alloc(T, capacity),
                .segmentLength = capacity / FUSE_SLOTS,
            };
            return self;
        }

        pub fn deinit(self: *Self, allocator: *Allocator) void {
            allocator.destroy(self);
        }

        /// reports if the specified key is within the set with false-positive rate.
        pub inline fn contain(self: *Self, key: u64) bool {
            var hash = util.mix_split(key, self.seed);
            var f = @truncate(T, util.fingerprint(hash));
            var r0 = @truncate(u32, hash);
            var r1 = @truncate(u32, util.rotl64(hash, 21));
            var r2 = @truncate(u32, util.rotl64(hash, 42));
            var r3 = @truncate(u32, (0xBF58476D1CE4E5B9 *% hash) >> 32);
            var seg = util.reduce(r0, FUSE_SEGMENT_COUNT);
            var sl: u64 = self.segmentLength;
            var h0 = (seg + 0) * sl + util.reduce(r1, @truncate(u32, sl));
            var h1 = (seg + 1) * sl + util.reduce(r2, @truncate(u32, sl));
            var h2 = (seg + 2) * sl + util.reduce(r3, @truncate(u32, sl));
            return f == (self.fingerprints[h0] ^ self.fingerprints[h1] ^ self.fingerprints[h2]);
        }

        /// reports the size in bytes of the filter.
        pub inline fn size_in_bytes(self: *Self) usize {
            return FUSE_SLOTS * self.segmentLength * @sizeOf(T) + @sizeOf(Self);
        }

        /// populates the filter with the given keys.
        ///
        /// The caller is responsible for ensuring that there are no duplicated keys.
        ///
        /// The inner loop will run up to maxIterations times (default 100) and will never fail,
        /// except if there are duplicated keys.
        ///
        /// The provided allocator will be used for creating temporary buffers that do not outlive the
        /// function call.
        pub fn populate(self: *Self, allocator: *Allocator, keys: []u64) !bool {
            var rng_counter: u64 = 1;
            self.seed = util.rng_splitmix64(&rng_counter);

            var sets = try allocator.alloc(Set, self.segmentLength * FUSE_SLOTS);
            defer allocator.free(sets);

            var Q = try allocator.alloc(Keyindex, sets.len);
            defer allocator.free(Q);

            var stack = try allocator.alloc(Keyindex, keys.len);
            defer allocator.free(stack);

            var loop: usize = 0;
            while (true) : (loop += 1) {
                if (loop + 1 > self.maxIterations) {
                    return false; // too many iterations, keys are not unique.
                }
                for (sets[0..sets.len]) |*b| b.* = std.mem.zeroes(Set);

                for (keys) |key, i| {
                    var hs = get_h0_h1_h2(self, key);
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
                for (sets) |set, i| {
                    if (set.count == 1) {
                        Q[Qsize].index = @intCast(u32, i);
                        Q[Qsize].hash = sets[i].fusemask;
                        Qsize += 1;
                    }
                }

                var stack_size: usize = 0;
                while (Qsize > 0) {
                    Qsize -= 1;
                    var keyindex = Q[Qsize];
                    var index = keyindex.index;
                    if (sets[index].count == 0) {
                        continue; // not actually possible after the initial scan.
                    }
                    var hash = keyindex.hash;
                    var hs = get_just_h0_h1_h2(self, hash);

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
                if (stack_size == keys.len) {
                    // success
                    break;
                }
                self.seed = util.rng_splitmix64(&rng_counter);
            }

            var stack_size = keys.len;
            while (stack_size > 0) {
                stack_size -= 1;
                var ki = stack[stack_size];
                var hs = get_just_h0_h1_h2(self, ki.hash);
                var hsh: T = @truncate(T, util.fingerprint(ki.hash));
                if (ki.index == hs.h0) {
                    hsh ^= self.fingerprints[hs.h1] ^ self.fingerprints[hs.h2];
                } else if (ki.index == hs.h1) {
                    hsh ^= self.fingerprints[hs.h0] ^ self.fingerprints[hs.h2];
                } else {
                    hsh ^= self.fingerprints[hs.h0] ^ self.fingerprints[hs.h1];
                }
                self.fingerprints[ki.index] = hsh;
            }
            return true;
        }

        inline fn get_h0_h1_h2(self: *Self, k: u64) Hashes {
            var hash = util.mix_split(k, self.seed);
            var r0 = @truncate(u32, hash);
            var r1 = @truncate(u32, util.rotl64(hash, 21));
            var r2 = @truncate(u32, util.rotl64(hash, 42));
            var r3 = @truncate(u32, (0xBF58476D1CE4E5B9 *% hash) >> 32);
            var seg = util.reduce(r0, FUSE_SEGMENT_COUNT);
            var sl = self.segmentLength;
            return Hashes{
                .h = hash,
                .h0 = @truncate(u32, @intCast(u64, (seg + 0)) * sl + @intCast(u64, util.reduce(r1, @truncate(u32, sl)))),
                .h1 = @truncate(u32, @intCast(u64, (seg + 1)) * sl + @intCast(u64, util.reduce(r2, @truncate(u32, sl)))),
                .h2 = @truncate(u32, @intCast(u64, (seg + 2)) * sl + @intCast(u64, util.reduce(r3, @truncate(u32, sl)))),
            };
        }

        inline fn get_just_h0_h1_h2(self: *Self, hash: u64) H0h1h2 {
            var r0 = @truncate(u32, hash);
            var r1 = @truncate(u32, util.rotl64(hash, 21));
            var r2 = @truncate(u32, util.rotl64(hash, 42));
            var r3 = @truncate(u32, (0xBF58476D1CE4E5B9 *% hash) >> 32);
            var seg = util.reduce(r0, FUSE_SEGMENT_COUNT);
            var sl = self.segmentLength;
            return H0h1h2{
                .h0 = @truncate(u32, @intCast(u64, (seg + 0)) * sl + @intCast(u64, util.reduce(r1, @truncate(u32, sl)))),
                .h1 = @truncate(u32, @intCast(u64, (seg + 1)) * sl + @intCast(u64, util.reduce(r2, @truncate(u32, sl)))),
                .h2 = @truncate(u32, @intCast(u64, (seg + 2)) * sl + @intCast(u64, util.reduce(r3, @truncate(u32, sl)))),
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
    const filter = try Fuse(T).init(allocator, size);
    comptime filter.maxIterations = 100; // proof we can modify maxIterations at comptime.
    defer filter.deinit(allocator);

    var keys = try allocator.alloc(u64, size);
    defer allocator.free(keys);
    for (keys) |key, i| {
        keys[i] = i;
    }

    var success = try filter.populate(allocator, keys[0..]);
    testing.expect(success == true);

    testing.expect(filter.contain(1) == true);
    testing.expect(filter.contain(5) == true);
    testing.expect(filter.contain(9) == true);
    testing.expect(filter.contain(1234) == true);
    testing.expectEqual(@as(usize, size_in_bytes), filter.size_in_bytes());

    for (keys) |key| {
        testing.expect(filter.contain(key) == true);
    }

    var random_matches: u64 = 0;
    const trials = 10000000;
    var i: u64 = 0;
    var default_prng = std.rand.DefaultPrng.init(0);
    while (i < trials) : (i += 1) {
        var random_key: u64 = default_prng.random.uintAtMost(u64, std.math.maxInt(u64));
        if (filter.contain(random_key)) {
            if (random_key >= keys.len) {
                random_matches += 1;
            }
        }
    }

    std.debug.print("fpp {d:3.10} (estimated) \n", .{@intToFloat(f64, random_matches) * 1.0 / trials});
    std.debug.print("bits per entry {d:3.1}\n", .{@intToFloat(f64, filter.size_in_bytes()) * 8.0 / @intToFloat(f64, size)});
}

test "fuse4" {
    try fuseTest(u4, 1000000/2, 568792);
}

test "fuse8" {
    try fuseTest(u8, 1000000, 1137646);
}

test "fuse16" {
    try fuseTest(u16, 1000000, 2275252);
}
