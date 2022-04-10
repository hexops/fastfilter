const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;
const testing = std.testing;

const util = @import("util.zig");
const Error = util.Error;

/// BinaryFuse8 provides a binary fuse filter with 8-bit fingerprints.
///
/// See `BinaryFuse` for more details.
pub const BinaryFuse8 = BinaryFuse(u8);

/// A binary fuse filter. This is an extension of fuse filters:
///
/// Dietzfelbinger & Walzer's fuse filters, described in "Dense Peelable Random Uniform Hypergraphs",
/// https://arxiv.org/abs/1907.04749, can accomodate fill factors up to 87.9% full, rather than
/// 1 / 1.23 = 81.3%. In the 8-bit case, this reduces the memory usage from 9.84 bits per entry to
/// 9.1 bits.
///
/// An issue with traditional fuse filters is that the algorithm requires a large number of unique
/// keys in order for population to succeed, see [FastFilter/xor_singleheader#21](https://github.com/FastFilter/xor_singleheader/issues/21).
/// If you have few (<~125k consecutive) keys, fuse filter creation would fail.
///
/// By contrast, binary fuse filters, a revision of fuse filters made by Thomas Mueller Graf &
/// Daniel Lemire do not suffer from this issue. See https://github.com/FastFilter/xor_singleheader/issues/21
///
/// Note: We assume that you have a large set of 64-bit integers and you want a data structure to
/// do membership tests using no more than ~8 or ~16 bits per key. If your initial set is made of
/// strings or other types, you first need to hash them to a 64-bit integer.
pub fn BinaryFuse(comptime T: type) type {
    return struct {
        allocator: Allocator,
        seed: u64,
        segment_length: u32,
        segment_length_mask: u32,
        segment_count: u32,
        segment_count_length: u32,
        fingerprints: []T,

        /// probability of success should always be > 0.5 so 100 iterations is highly unlikely
        max_iterations: usize = 100,

        const Self = @This();

        /// initializes a binary fuse filter with enough capacity for a set containing up to `size`
        /// elements.
        ///
        /// `deinit()` must be called by the caller to free the memory.
        pub fn init(allocator: Allocator, size: usize) !*Self {
            const arity: u32 = 3;
            var segment_length = calculateSegmentLength(arity, size);
            if (segment_length > 262144) {
                segment_length = 262144;
            }
            const segment_length_mask = segment_length - 1;
            const size_factor: f64 = if (size == 0) 4 else calculateSizeFactor(arity, size);
            const capacity = if (size <= 1) 0 else @floatToInt(u32, math.round(@intToFloat(f64, size) * size_factor));
            const init_segment_count: u32 = (capacity + segment_length - 1) / segment_length -% (arity - 1);
            var slice_length = (init_segment_count +% arity - 1) * segment_length;
            var segment_count = (slice_length + segment_length - 1) / segment_length;
            if (segment_count <= arity - 1) {
                segment_count = 1;
            } else {
                segment_count = segment_count - (arity - 1);
            }
            slice_length = (segment_count + arity - 1) * segment_length;
            const segment_count_length = segment_count * segment_length;

            const self = try allocator.create(Self);
            self.* = Self{
                .allocator = allocator,
                .seed = undefined,
                .segment_length = segment_length,
                .segment_length_mask = segment_length_mask,
                .segment_count = segment_count,
                .segment_count_length = segment_count_length,
                .fingerprints = try allocator.alloc(T, slice_length),
            };
            return self;
        }

        pub inline fn deinit(self: *Self) void {
            self.allocator.free(self.fingerprints);
            self.allocator.destroy(self);
        }

        /// reports the size in bytes of the filter.
        pub inline fn sizeInBytes(self: *Self) usize {
            return self.fingerprints.len * @sizeOf(T) + @sizeOf(Self);
        }

        /// populates the filter with the given keys.
        ///
        /// The function could return an error after too many iterations, but it is statistically
        /// unlikely and you probably don't need to worry about it.
        ///
        /// The provided allocator will be used for creating temporary buffers that do not outlive the
        /// function call.
        pub fn populate(self: *Self, allocator: Allocator, keys: []u64) Error!void {
            const iter = try util.SliceIterator(u64).init(allocator, keys);
            defer iter.deinit();
            return self.populateIter(allocator, iter);
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
            if (keys.len() == 0) {
                return;
            }
            var rng_counter: u64 = 0x726b2b9d438b9d4d;
            self.seed = util.rngSplitMix64(&rng_counter);

            var size = keys.len();
            const reverse_order = try allocator.alloc(u64, size + 1);
            defer allocator.free(reverse_order);
            std.mem.set(u64, reverse_order, 0);

            const capacity = self.fingerprints.len;
            const alone = try allocator.alloc(u32, capacity);
            defer allocator.free(alone);

            const t2count = try allocator.alloc(T, capacity);
            defer allocator.free(t2count);
            std.mem.set(T, t2count, 0);

            const reverse_h = try allocator.alloc(T, size);
            defer allocator.free(reverse_h);

            const t2hash = try allocator.alloc(u64, capacity);
            defer allocator.free(t2hash);
            std.mem.set(u64, t2hash, 0);

            var block_bits: u5 = 1;
            while ((@as(u32, 1) << block_bits) < self.segment_count) {
                block_bits += 1;
            }
            const block: u32 = @as(u32, 1) << block_bits;

            const start_pos = try allocator.alloc(u32, @as(usize, 1) << block_bits);
            defer allocator.free(start_pos);

            var h012: [5]u32 = undefined;

            reverse_order[size] = 1;
            var loop: usize = 0;
            while (true) : (loop += 1) {
                if (loop + 1 > self.max_iterations) {
                    return Error.KeysLikelyNotUnique; // too many iterations, keys are not unique.
                }

                var i: u32 = 0;
                while (i < block) : (i += 1) {
                    // important : i * size would overflow as a 32-bit number in some
                    // cases.
                    start_pos[i] = @truncate(u32, (@intCast(u64, i) * size) >> block_bits);
                }

                const mask_block: u64 = block - 1;
                while (keys.next()) |key| {
                    var sum: u64 = undefined;
                    _ = @addWithOverflow(u64, key, self.seed, &sum);
                    const hash: u64 = util.murmur64(sum);

                    const shift_count = @as(usize, 64) - @as(usize, block_bits);
                    var segment_index: u64 = if (shift_count >= 63) 0 else hash >> @truncate(u6, shift_count);
                    while (reverse_order[start_pos[segment_index]] != 0) {
                        segment_index += 1;
                        segment_index &= mask_block;
                    }
                    reverse_order[start_pos[segment_index]] = hash;
                    start_pos[segment_index] += 1;
                }

                var err = false;
                var duplicates: u32 = 0;
                i = 0;
                while (i < size) : (i += 1) {
                    const hash = reverse_order[i];
                    const h0 = self.fuseHash(0, hash);
                    t2count[h0] += 4;
                    t2hash[h0] ^= hash;
                    const h1 = self.fuseHash(1, hash);
                    t2count[h1] += 4;
                    t2count[h1] ^= 1;
                    t2hash[h1] ^= hash;
                    const h2 = self.fuseHash(2, hash);
                    t2count[h2] += 4;
                    t2hash[h2] ^= hash;
                    t2count[h2] ^= 2;
                    // If we have duplicated hash values, then it is likely that the next comparison
                    // is true
                    if (t2hash[h0] & t2hash[h1] & t2hash[h2] == 0) {
                        // next we do the actual test
                        if (((t2hash[h0] == 0) and (t2count[h0] == 8)) or ((t2hash[h1] == 0) and (t2count[h1] == 8)) or ((t2hash[h2] == 0) and (t2count[h2] == 8))) {
                            duplicates += 1;
                            t2count[h0] -= 4;
                            t2hash[h0] ^= hash;
                            t2count[h1] -= 4;
                            t2count[h1] ^= 1;
                            t2hash[h1] ^= hash;
                            t2count[h2] -= 4;
                            t2count[h2] ^= 2;
                            t2hash[h2] ^= hash;
                        }
                    }
                    err = (t2count[h0] < 4) or err;
                    err = (t2count[h1] < 4) or err;
                    err = (t2count[h2] < 4) or err;
                }
                if (err) {
                    i = 0;
                    while (i < size) : (i += 1) {
                        reverse_order[i] = 0;
                    }
                    i = 0;
                    while (i < capacity) : (i += 1) {
                        t2count[i] = 0;
                        t2hash[i] = 0;
                    }
                    self.seed = util.rngSplitMix64(&rng_counter);
                    continue;
                }

                // End of key addition
                var Qsize: u32 = 0;
                // Add sets with one key to the queue.
                i = 0;
                while (i < capacity) : (i += 1) {
                    alone[Qsize] = i;
                    Qsize += if ((t2count[i] >> 2) == 1) @as(u32, 1) else @as(u32, 0);
                }
                var stacksize: u32 = 0;
                while (Qsize > 0) {
                    Qsize -= 1;
                    const index: u32 = alone[Qsize];
                    if ((t2count[index] >> 2) == 1) {
                        const hash = t2hash[index];

                        //h012[0] = self.fuseHash(0, hash);
                        h012[1] = self.fuseHash(1, hash);
                        h012[2] = self.fuseHash(2, hash);
                        h012[3] = self.fuseHash(0, hash); // == h012[0];
                        h012[4] = h012[1];
                        const found = t2count[index] & 3;
                        reverse_h[stacksize] = found;
                        reverse_order[stacksize] = hash;
                        stacksize += 1;
                        const other_index1 = h012[found + 1];
                        alone[Qsize] = other_index1;
                        Qsize += if ((t2count[other_index1] >> 2) == 2) @as(u32, 1) else @as(u32, 0);

                        t2count[other_index1] -= 4;
                        t2count[other_index1] ^= fuseMod3(T, found + 1);
                        t2hash[other_index1] ^= hash;

                        const other_index2 = h012[found + 2];
                        alone[Qsize] = other_index2;
                        Qsize += if ((t2count[other_index2] >> 2) == 2) @as(u32, 1) else @as(u32, 0);
                        t2count[other_index2] -= 4;
                        t2count[other_index2] ^= fuseMod3(T, found + 2);
                        t2hash[other_index2] ^= hash;
                    }
                }
                if (stacksize + duplicates == size) {
                    // success
                    size = stacksize;
                    break;
                }
                std.mem.set(u64, reverse_order[0..size], 0);
                std.mem.set(T, t2count[0..capacity], 0);
                std.mem.set(u64, t2hash[0..capacity], 0);
                self.seed = util.rngSplitMix64(&rng_counter);
            }
            if (size == 0) return;

            var i: u32 = @truncate(u32, size - 1);
            while (i < size) : (i -%= 1) {
                // the hash of the key we insert next
                const hash: u64 = reverse_order[i];
                const xor2: T = @truncate(T, util.fingerprint(hash));
                const found: T = reverse_h[i];
                h012[0] = self.fuseHash(0, hash);
                h012[1] = self.fuseHash(1, hash);
                h012[2] = self.fuseHash(2, hash);
                h012[3] = h012[0];
                h012[4] = h012[1];
                self.fingerprints[h012[found]] = xor2 ^ self.fingerprints[h012[found + 1]] ^ self.fingerprints[h012[found + 2]];
            }
        }

        /// reports if the specified key is within the set with false-positive rate.
        pub inline fn contain(self: *Self, key: u64) bool {
            var hash = util.mixSplit(key, self.seed);
            var f = @truncate(T, util.fingerprint(hash));
            const hashes = self.fuseHashBatch(hash);
            f ^= self.fingerprints[hashes.h0] ^ self.fingerprints[hashes.h1] ^ self.fingerprints[hashes.h2];
            return f == 0;
        }

        inline fn fuseHashBatch(self: *Self, hash: u64) Hashes {
            const hi: u64 = mulhi(hash, self.segment_count_length);
            var ans: Hashes = undefined;
            ans.h0 = @truncate(u32, hi);
            ans.h1 = ans.h0 + self.segment_length;
            ans.h2 = ans.h1 + self.segment_length;
            ans.h1 ^= @truncate(u32, hash >> 18) & self.segment_length_mask;
            ans.h2 ^= @truncate(u32, hash) & self.segment_length_mask;
            return ans;
        }

        inline fn fuseHash(self: *Self, index: usize, hash: u64) u32 {
            var h = mulhi(hash, self.segment_count_length);
            h +%= index * self.segment_length;
            // keep the lower 36 bits
            const hh: u64 = hash & ((@as(u64, 1) << 36) - 1);
            // index 0: right shift by 36; index 1: right shift by 18; index 2: no shift
            //
            // NOTE(slimsag): using u64 here instead of size_it as in upstream C implementation; I think
            // that size_t may be incorrect for 32-bit platforms?
            const shift_count = (36 - 18 * index);
            if (shift_count >= 63) {
                h ^= 0 & self.segment_length_mask;
            } else {
                h ^= (hh >> @truncate(u6, shift_count)) & self.segment_length_mask;
            }
            return @truncate(u32, h);
        }
    };
}

inline fn mulhi(a: u64, b: u64) u64 {
    return @truncate(u64, (@intCast(u128, a) *% @intCast(u128, b)) >> 64);
}

const Hashes = struct {
    h0: u32,
    h1: u32,
    h2: u32,
};

inline fn calculateSegmentLength(arity: u32, size: usize) u32 {
    // These parameters are very sensitive. Replacing `floor` by `round` can substantially affect
    // the construction time.
    if (size == 0) return 4;
    if (arity == 3) {
        const shift_count = @truncate(u32, relaxedFloatToInt(usize, math.floor(math.log(f64, math.e, @intToFloat(f64, size)) / math.log(f64, math.e, 3.33) + 2.25)));
        return if (shift_count >= 31) 0 else @as(u32, 1) << @truncate(u5, shift_count);
    } else if (arity == 4) {
        const shift_count = @truncate(u32, relaxedFloatToInt(usize, math.floor(math.log(f64, math.e, @intToFloat(f64, size)) / math.log(f64, math.e, 2.91) - 0.5)));
        return if (shift_count >= 31) 0 else @as(u32, 1) << @truncate(u5, shift_count);
    }
    return 65536;
}

inline fn relaxedFloatToInt(comptime DestType: type, float: anytype) DestType {
    if (math.isInf(float) or math.isNegativeInf(float) or math.isNan(float)) {
        return 1 << @bitSizeOf(DestType) - 1;
    }
    return @floatToInt(DestType, float);
}

inline fn max(a: f64, b: f64) f64 {
    return if (a < b) b else a;
}

inline fn calculateSizeFactor(arity: u32, size: usize) f64 {
    if (arity == 3) {
        return max(1.125, 0.875 + 0.25 * math.log(f64, math.e, 1000000.0) / math.log(f64, math.e, @intToFloat(f64, size)));
    } else if (arity == 4) {
        return max(1.075, 0.77 + 0.305 * math.log(f64, math.e, 600000.0) / math.log(f64, math.e, @intToFloat(f64, size)));
    }
    return 2.0;
}

inline fn fuseMod3(comptime T: type, x: T) T {
    return if (x > 2) x - 3 else x;
}

const special_size_duplicates = 1337;

fn binaryFuseTest(T: anytype, size: usize, size_in_bytes: usize) !void {
    const allocator = std.heap.page_allocator;
    const filter = try BinaryFuse(T).init(allocator, size);
    comptime filter.max_iterations = 100; // proof we can modify max_iterations at comptime.
    defer filter.deinit();

    var keys: []u64 = undefined;
    if (size == special_size_duplicates) {
        const duplicate_keys: [6]u64 = .{ 303, 1, 77, 31, 241, 303 };
        keys = try allocator.alloc(u64, duplicate_keys.len);
        for (keys) |_, i| {
            keys[i] = duplicate_keys[i];
        }
    } else {
        keys = try allocator.alloc(u64, size);
        for (keys) |_, i| {
            keys[i] = i;
        }
    }
    defer allocator.free(keys);

    try filter.populate(allocator, keys[0..]);

    if (size != special_size_duplicates) {
        if (size == 0) {
            try testing.expect(!filter.contain(0));
            try testing.expect(!filter.contain(1));
        }
        if (size > 0) try testing.expect(filter.contain(0));
        if (size > 1) try testing.expect(filter.contain(1));
        if (size > 9) {
            try testing.expect(filter.contain(1) == true);
            try testing.expect(filter.contain(5) == true);
            try testing.expect(filter.contain(9) == true);
        }
        if (size > 1234) try testing.expect(filter.contain(1234) == true);
    }
    try testing.expectEqual(@as(usize, size_in_bytes), filter.sizeInBytes());

    for (keys) |key| {
        try testing.expect(filter.contain(key) == true);
    }

    var random_matches: u64 = 0;
    const trials = 10000000;
    var i: u64 = 0;
    var rng = std.rand.DefaultPrng.init(0);
    const random = rng.random();
    while (i < trials) : (i += 1) {
        var random_key: u64 = random.uintAtMost(u64, std.math.maxInt(u64));
        if (filter.contain(random_key)) {
            if (random_key >= keys.len) {
                random_matches += 1;
            }
        }
    }

    std.debug.print("fpp {d:3.10} (estimated) \n", .{@intToFloat(f64, random_matches) * 1.0 / trials});
    std.debug.print("bits per entry {d:3.1}\n", .{@intToFloat(f64, filter.sizeInBytes()) * 8.0 / @intToFloat(f64, size)});
}

test "binaryFuse8_small_input_edge_cases" {
    // See https://github.com/FastFilter/xor_singleheader/issues/26
    try binaryFuseTest(u8, 0, 76);
    try binaryFuseTest(u8, 1, 76);
    try binaryFuseTest(u8, 2, 76);
    try binaryFuseTest(u8, 3, 88);
}

test "binaryFuse8_zero" {
    try binaryFuseTest(u8, 0, 76);
}

test "binaryFuse8_1" {
    try binaryFuseTest(u8, 1, 76);
}

test "binaryFuse8_10" {
    try binaryFuseTest(u8, 10, 112);
}

test "binaryFuse8" {
    try binaryFuseTest(u8, 1_000_000, 1130560);
}

test "binaryFuse8_2m" {
    try binaryFuseTest(u8, 2_000_000, 2261056);
}

test "binaryFuse8_5m" {
    try binaryFuseTest(u8, 5_000_000, 5636160);
}

test "binaryFuse16" {
    try binaryFuseTest(u16, 1_000_000, 2261056);
}

test "binaryFuse32" {
    try binaryFuseTest(u32, 1_000_000, 4522048);
}

test "binaryFuse8_duplicate_keys" {
    try binaryFuseTest(u8, special_size_duplicates, 2112);
}

test "binaryFuse8_mid_num_keys" {
    try binaryFuseTest(u8, 11500, 14400);
}
