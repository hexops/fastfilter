const std = @import("std");
const testing = std.testing;

// The same as `AutoUnique`, but accepts custom hash and equality functions.
pub fn Unique(
    comptime T: type,
    comptime Context: type,
    comptime hash: fn (
        ctx: Context,
        key: T,
    ) u64,
    comptime eql: fn (ctx: Context, a: T, b: T) bool,
) fn (Context, []T) []T {
    return struct {
        pub fn inPlace(ctx: Context, data: []T) []T {
            return doInPlace(ctx, data, 0);
        }

        fn swap(data: []T, i: usize, j: usize) void {
            var tmp = data[i];
            data[i] = data[j];
            data[j] = tmp;
        }

        fn doInPlace(ctx: Context, dataIn: []T, start: usize) []T {
            if (dataIn.len - start < 2) {
                return dataIn;
            }

            const sentinel = dataIn[start];
            const data = dataIn[start + 1 .. dataIn.len];

            var index: usize = 0;
            while (index < data.len) {
                if (eql(ctx, data[index], sentinel)) {
                    index += 1;
                    continue;
                }

                const hsh = hash(ctx, data[index]) % data.len;
                if (index == hsh) {
                    index += 1;
                    continue;
                }

                if (eql(ctx, data[index], data[hsh])) {
                    data[index] = sentinel;
                    index += 1;
                    continue;
                }

                if (eql(ctx, data[hsh], sentinel)) {
                    swap(data, hsh, index);
                    index += 1;
                    continue;
                }

                const hashHash = hash(ctx, data[hsh]) % data.len;
                if (hashHash != hsh) {
                    swap(data, index, hsh);
                    if (hsh < index) {
                        index += 1;
                    }
                } else {
                    index += 1;
                }
            }

            var swapPos: usize = 0;
            for (data) |v, i| {
                if ((!eql(ctx, v, sentinel)) and (i == (hash(ctx, v) % data.len))) {
                    swap(data, i, swapPos);
                    swapPos += 1;
                }
            }

            var sentinelPos: usize = data.len;
            var i = swapPos;
            while (i < sentinelPos) {
                if (eql(ctx, data[i], sentinel)) {
                    sentinelPos -= 1;
                    swap(data, i, sentinelPos);
                } else {
                    i += 1;
                }
            }

            return doInPlace(ctx, dataIn[0 .. sentinelPos + start + 1], start + swapPos + 1);
        }
    }.inPlace;
}

/// Modifies a slice in-place to contain only unique values.
///
/// The input slice is modified, with element positions being swapped. The returned slice is an
/// equal length or subset with duplicate entries omitted.
///
/// It is guaranteed to be O(1) in axillary space, and is typically O(N) time complexity.
/// Order preservation is not guaranteed.
///
/// The algorithm is described here: https://stackoverflow.com/a/1533667
///
/// To hash T and perform equality checks of T, `std.hash_map.getAutoHashFn` and
/// `std.hash_map.getAutoEqlFn` are used, which support most data types. Use `Unique` if you need
/// to use your own hash and equality functions.
pub fn AutoUnique(comptime T: type, comptime Context: type) fn (void, []T) []T {
    return comptime Unique(
        T,
        Context,
        std.hash_map.getAutoHashFn(T, Context),
        std.hash_map.getAutoEqlFn(T, Context),
    );
}

test "AutoUnique_simple" {
    var array = [_]i32{ 1, 2, 2, 3, 3, 4, 2, 1, 4, 1, 2, 3, 4, 4, 3, 2, 1 };
    const unique = AutoUnique(i32, void)({}, array[0..]);
    const expected = &[_]i32{ 1, 4, 3, 2 };
    try testing.expectEqualSlices(i32, expected, unique);
}

test "AutoUnique_complex" {
    // Produce an array with 3x duplicated keys
    const allocator = std.heap.page_allocator;
    const size = 10;
    var keys = try allocator.alloc(u64, size * 3);
    defer allocator.free(keys);

    var i: usize = 0;
    while (i < size * 3) : (i += 3) {
        keys[i] = i % size;
        keys[i + 1] = i % size;
        keys[i + 2] = i % size;
    }

    const unique = AutoUnique(u64, void)({}, keys[0..]);
    try testing.expect(unique.len == size);
}
