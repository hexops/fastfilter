const std = @import("std");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Error = util.Error;

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

        /// probability of success should always be > 0.5 so 100 iterations is highly unlikely
        max_iterations: usize = 100,

        const Self = @This();

        /// initializes a Xor filter with enough capacity for a set containing up to `size` elements.
        ///
        /// `deinit()` must be called by the caller to free the memory.
        pub fn init(allocator: Allocator, size: usize) !Self {
            var capacity = @as(usize, @intFromFloat(32 + 1.23 * @as(f64, @floatFromInt(size))));
            capacity = capacity / 3 * 3;
            const fingerprints = try allocator.alloc(T, capacity);
            @memset(fingerprints, 0);
            return Self{
                .seed = 0,
                .fingerprints = fingerprints,
                .blockLength = capacity / 3,
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
            const bl = @as(u32, @truncate(self.blockLength));
            const h0: u32 = util.reduce(r0, bl);
            const h1: u32 = util.reduce(r1, bl) + bl;
            const h2: u32 = util.reduce(r2, bl) + 2 * bl;
            return f == (self.fingerprints[h0] ^ self.fingerprints[h1] ^ self.fingerprints[h2]);
        }

        /// reports the size in bytes of the filter.
        pub inline fn sizeInBytes(self: *const Self) usize {
            return 3 * self.blockLength * @sizeOf(T) + @sizeOf(Self);
        }

        /// populates the filter with the given keys.
        ///
        /// The caller is responsible for ensuring that there are no duplicated keys.
        ///
        /// The inner loop will run up to max_iterations (default 100) and should never fail,
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

            var sets = try allocator.alloc(Set, self.blockLength * 3);
            defer allocator.free(sets);

            var Q = try allocator.alloc(Keyindex, sets.len);
            defer allocator.free(Q);

            var stack = try allocator.alloc(Keyindex, keys.len());
            defer allocator.free(stack);

            var sets0 = sets;
            var sets1 = sets[self.blockLength..];
            var sets2 = sets[2 * self.blockLength ..];
            var Q0 = Q;
            var Q1 = Q[self.blockLength..];
            var Q2 = Q[2 * self.blockLength ..];

            var loop: usize = 0;
            while (true) : (loop += 1) {
                if (loop + 1 > self.max_iterations) {
                    return Error.KeysLikelyNotUnique; // too many iterations, keys are not unique.
                }
                for (sets[0..sets.len]) |*b| b.* = std.mem.zeroes(Set);

                while (keys.next()) |key| {
                    const hs = self.getH0H1H2(key);
                    sets0[hs.h0].xormask ^= hs.h;
                    sets0[hs.h0].count += 1;
                    sets1[hs.h1].xormask ^= hs.h;
                    sets1[hs.h1].count += 1;
                    sets2[hs.h2].xormask ^= hs.h;
                    sets2[hs.h2].count += 1;
                }

                // TODO(upstream): the flush should be sync with the detection that follows scan values
                // with a count of one.
                var Q0size: usize = 0;
                var Q1size: usize = 0;
                var Q2size: usize = 0;
                {
                    var i: usize = 0;
                    while (i < self.blockLength) : (i += 1) {
                        if (sets0[i].count == 1) {
                            Q0[Q0size].index = @as(u32, @intCast(i));
                            Q0[Q0size].hash = sets0[i].xormask;
                            Q0size += 1;
                        }
                    }
                }
                {
                    var i: usize = 0;
                    while (i < self.blockLength) : (i += 1) {
                        if (sets1[i].count == 1) {
                            Q1[Q1size].index = @as(u32, @intCast(i));
                            Q1[Q1size].hash = sets1[i].xormask;
                            Q1size += 1;
                        }
                    }
                }
                {
                    var i: usize = 0;
                    while (i < self.blockLength) : (i += 1) {
                        if (sets2[i].count == 1) {
                            Q2[Q2size].index = @as(u32, @intCast(i));
                            Q2[Q2size].hash = sets2[i].xormask;
                            Q2size += 1;
                        }
                    }
                }

                var stack_size: usize = 0;
                while (Q0size + Q1size + Q2size > 0) {
                    while (Q0size > 0) {
                        Q0size -%= 1;
                        const keyindex = Q0[Q0size];
                        const index = keyindex.index;
                        if (sets0[index].count == 0) {
                            continue; // not actually possible after the initial scan.
                        }
                        const hash = keyindex.hash;
                        const h1 = self.getH1(hash);
                        const h2 = self.getH2(hash);

                        stack[stack_size] = keyindex;
                        stack_size += 1;
                        sets1[h1].xormask ^= hash;
                        sets1[h1].count -%= 1;
                        if (sets1[h1].count == 1) {
                            Q1[Q1size].index = h1;
                            Q1[Q1size].hash = sets1[h1].xormask;
                            Q1size += 1;
                        }
                        sets2[h2].xormask ^= hash;
                        sets2[h2].count -%= 1;
                        if (sets2[h2].count == 1) {
                            Q2[Q2size].index = h2;
                            Q2[Q2size].hash = sets2[h2].xormask;
                            Q2size += 1;
                        }
                    }
                    while (Q1size > 0) {
                        Q1size -%= 1;
                        var keyindex = Q1[Q1size];
                        const index = keyindex.index;
                        if (sets1[index].count == 0) {
                            continue; // not actually possible after the initial scan.
                        }
                        const hash = keyindex.hash;
                        const h0 = self.getH0(hash);
                        const h2 = self.getH2(hash);
                        keyindex.index += @as(u32, @truncate(self.blockLength));

                        stack[stack_size] = keyindex;
                        stack_size += 1;
                        sets0[h0].xormask ^= hash;
                        sets0[h0].count -%= 1;
                        if (sets0[h0].count == 1) {
                            Q0[Q0size].index = h0;
                            Q0[Q0size].hash = sets0[h0].xormask;
                            Q0size += 1;
                        }
                        sets2[h2].xormask ^= hash;
                        sets2[h2].count -%= 1;
                        if (sets2[h2].count == 1) {
                            Q2[Q2size].index = h2;
                            Q2[Q2size].hash = sets2[h2].xormask;
                            Q2size += 1;
                        }
                    }
                    while (Q2size > 0) {
                        Q2size -%= 1;
                        var keyindex = Q2[Q2size];
                        const index = keyindex.index;
                        if (sets2[index].count == 0) {
                            continue; // not actually possible after the initial scan.
                        }
                        const hash = keyindex.hash;
                        const h0 = self.getH0(hash);
                        const h1 = self.getH1(hash);
                        keyindex.index += @as(u32, @truncate(2 * @as(u64, @intCast(self.blockLength))));

                        stack[stack_size] = keyindex;
                        stack_size += 1;
                        sets0[h0].xormask ^= hash;
                        sets0[h0].count -%= 1;
                        if (sets0[h0].count == 1) {
                            Q0[Q0size].index = h0;
                            Q0[Q0size].hash = sets0[h0].xormask;
                            Q0size += 1;
                        }
                        sets1[h1].xormask ^= hash;
                        sets1[h1].count -%= 1;
                        if (sets1[h1].count == 1) {
                            Q1[Q1size].index = h1;
                            Q1[Q1size].hash = sets1[h1].xormask;
                            Q1size += 1;
                        }
                    }
                }
                if (stack_size == keys.len()) {
                    // success
                    break;
                }
                self.seed = util.rngSplitMix64(&rng_counter);
            }

            const fingerprints0: []T = self.fingerprints;
            const fingerprints1: []T = self.fingerprints[self.blockLength..];
            const fingerprints2: []T = self.fingerprints[2 * self.blockLength ..];

            var stack_size = keys.len();
            while (stack_size > 0) {
                stack_size -= 1;
                const ki = stack[stack_size];
                var val: u64 = util.fingerprint(ki.hash);
                if (ki.index < @as(u32, @truncate(self.blockLength))) {
                    val ^= fingerprints1[self.getH1(ki.hash)] ^ fingerprints2[self.getH2(ki.hash)];
                } else if (ki.index < 2 * @as(u32, @truncate(self.blockLength))) {
                    val ^= fingerprints0[self.getH0(ki.hash)] ^ fingerprints2[self.getH2(ki.hash)];
                } else {
                    val ^= fingerprints0[self.getH0(ki.hash)] ^ fingerprints1[self.getH1(ki.hash)];
                }
                self.fingerprints[ki.index] = @as(T, @truncate(val));
            }
            return;
        }

        inline fn getH0H1H2(self: *Self, k: u64) Hashes {
            const hash = util.mixSplit(k, self.seed);
            const r0 = @as(u32, @truncate(hash));
            const r1 = @as(u32, @truncate(util.rotl64(hash, 21)));
            const r2 = @as(u32, @truncate(util.rotl64(hash, 42)));
            return Hashes{
                .h = hash,
                .h0 = util.reduce(r0, @as(u32, @truncate(self.blockLength))),
                .h1 = util.reduce(r1, @as(u32, @truncate(self.blockLength))),
                .h2 = util.reduce(r2, @as(u32, @truncate(self.blockLength))),
            };
        }

        inline fn getH0(self: *Self, hash: u64) u32 {
            const r0 = @as(u32, @truncate(hash));
            return util.reduce(r0, @as(u32, @truncate(self.blockLength)));
        }

        inline fn getH1(self: *Self, hash: u64) u32 {
            const r1 = @as(u32, @truncate(util.rotl64(hash, 21)));
            return util.reduce(r1, @as(u32, @truncate(self.blockLength)));
        }

        inline fn getH2(self: *Self, hash: u64) u32 {
            const r2 = @as(u32, @truncate(util.rotl64(hash, 42)));
            return util.reduce(r2, @as(u32, @truncate(self.blockLength)));
        }
    };
}

const Set = struct {
    xormask: u64,
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

fn xorTest(T: anytype, size: usize) !void {
    const allocator = std.heap.page_allocator;
    var filter = try Xor(T).init(allocator, size);
    defer filter.deinit(allocator);

    var keys = try allocator.alloc(u64, size);
    defer allocator.free(keys);
    for (keys, 0..) |_, i| {
        keys[i] = i;
    }

    try filter.populate(allocator, keys[0..]);

    try testing.expect(filter.contain(1));
    try testing.expect(filter.contain(5));
    try testing.expect(filter.contain(9));
    try testing.expect(filter.contain(1234));

    var capacity = @as(usize, @intFromFloat(32 + 1.23 * @as(f64, @floatFromInt(size))));
    capacity = capacity / 3 * 3;
    const blockLength = capacity / 3;
    const expected_size = 3 * blockLength * @sizeOf(T) + @sizeOf(Xor(T));
    try testing.expectEqual(expected_size, filter.sizeInBytes());

    for (keys) |key| {
        try testing.expect(filter.contain(key));
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

    // const fpp = @floatFromInt(f64, random_matches) * 1.0 / trials;
    // std.debug.print("fpp {d:3.10} (estimated)\n", .{fpp});
    // std.debug.print("\t(keys={}, random_matches={}, trials={})\n", .{ size, random_matches, trials });
    // std.debug.print("\tbits per entry {d:3.1}\n", .{@floatFromInt(f64, filter.sizeInBytes()) * 8.0 / @floatFromInt(f64, size)});
}

test "xor8" {
    try xorTest(u8, 10000);
}

test "xor16" {
    try xorTest(u16, 10000);
}

test "xor20" {
    try xorTest(u20, 10000);
}

test "xor32" {
    // NOTE: We only use 1m keys here to keep the test running fast. With 100 million keys, the
    // test can take a minute or two on a 2020 Macbook and requires ~6.3 GiB of memory. Still,
    // estimated fpp is 0 - I leave it to the reader to estimate the fpp of xor32/xor64.
    //
    // If you have a really beefy machine, it would be cool to try this test with a huge amount of
    // keys and higher `trials` in `xorTest`.
    try xorTest(u32, 1000000);
}

test "xor64" {
    // NOTE: We only use 1m keys here to keep the test running fast. With 100 million keys, the
    // test can take a minute or two on a 2020 Macbook and requires ~6.3 GiB of memory. Still,
    // estimated fpp is 0 - I leave it to the reader to estimate the fpp of xor32/xor64.
    //
    // If you have a really beefy machine, it would be cool to try this test with a huge amount of
    // keys and higher `trials` in `xorTest`.
    try xorTest(u64, 1000000);
}
