# fastfilter: Binary fuse & xor filters for Zig 

[![CI](https://github.com/WonderBeat/fastfilter/workflows/CI/badge.svg)](https://github.com/WonderBeat/fastfilter/actions)

<a href="https://raw.githubusercontent.com/FastFilter/xor_singleheader/master/figures/comparison.png"><img align="right" src="https://raw.githubusercontent.com/FastFilter/xor_singleheader/master/figures/comparison.png" alt="comparison" width="400px"></img></a>

Binary fuse filters & xor filters are probabilistic data structures which allow for quickly checking whether an element is part of a set.

Both are faster and more concise than Bloom filters, and smaller than Cuckoo filters. Binary fuse filters are a bleeding-edge development and are competitive with Facebook's ribbon filters:

* Thomas Mueller Graf, Daniel Lemire, Binary Fuse Filters: Fast and Smaller Than Xor Filters (_not yet published_)
* Thomas Mueller Graf, Daniel Lemire, [Xor Filters: Faster and Smaller Than Bloom and Cuckoo Filters](https://arxiv.org/abs/1912.08258), Journal of Experimental Algorithmics 25 (1), 2020. DOI: 10.1145/3376122

## Benefits of Zig implementation

This is a [Zig](https://ziglang.org) implementation, which provides many practical benefits:

1. **Iterator-based:** you can populate xor or binary fuse filters using an iterator, without keeping your entire key set in-memory and without it being a contiguous array of keys. This can reduce memory usage when populating filters substantially.
2. **Distinct allocators:** you can provide separate Zig `std.mem.Allocator` implementations for the filter itself and population, enabling interesting opportunities like mmap-backed population of filters with low physical memory usage.
3. **Generic implementation:** use `Xor(u8)`, `Xor(u16)`, `BinaryFuse(u8)`, `BinaryFuse(u16)`, or experiment with more exotic variants like `Xor(u4)` thanks to Zig's [bit-width integers](https://ziglang.org/documentation/master/#Runtime-Integer-Values) and generic type system.

Zig's safety-checking and checked overflows has also enabled us to improve the upstream C/Go implementations where overflow and undefined behavior went unnoticed.[[1]](https://github.com/FastFilter/xor_singleheader/issues/26)

## Usage

Decide if xor or binary fuse filters fit your use case better: [should I use binary fuse filters or xor filters?](#should-i-use-binary-fuse-filters-or-xor-filters)

Get your keys into `u64` values. If you have strings, structs, etc. then use something like Zig's [`std.hash_map.getAutoHashFn`](https://ziglang.org/documentation/master/std/#std;hash_map.getAutoHashFn) to convert your keys to `u64` first. ("It is not important to have a good hash function, but collisions should be unlikely (~1/2^64).")

Create a `build.zig.zon` file in your project (replace `$LATEST_COMMIT` with the latest commit hash):

```
.{
    .name = "mypkg",
    .version = "0.1.0",
    .dependencies = .{
        .fastfilter = .{
            .url = "https://github.com/hexops/fastfilter/archive/$LATEST_COMMIT.tar.gz",
        },
    },
}
```

Run `zig build` in your project, and the compiler instruct you to add a `.hash = "..."` field next to `.url`.

Then use the dependency in your `build.zig`:

```zig
pub fn build(b: *std.Build) void {
    ...
    exe.addModule("fastfilter", b.dependency("fastfilter", .{
        .target = target,
        .optimize = optimize,
    }).module("fastfilter"));
}
```

In your `main.zig`, make use of the library:

```zig
const std = @import("std");
const testing = std.testing;
const fastfilter = @import("fastfilter");

test "mytest" {
    const allocator = std.heap.page_allocator;

    // Initialize the binary fuse filter with room for 1 million keys.
    const size = 1_000_000;
    var filter = try fastfilter.BinaryFuse8.init(allocator, size);
    defer filter.deinit(allocator);

    // Generate some consecutive keys.
    var keys = try allocator.alloc(u64, size);
    defer allocator.free(keys);
    for (keys, 0..) |key, i| {
        _ = key;
        keys[i] = i;
    }

    // Populate the filter with our keys. You can't update a xor / binary fuse filter after the
    // fact, instead you should build a new one.
    try filter.populate(allocator, keys[0..]);

    // Now we can quickly test for containment. So fast!
    try testing.expect(filter.contain(1) == true);
}
```

(you can just add this project as a Git submodule in yours for now, as [Zig's official package manager is still under way](https://github.com/ziglang/zig/issues/943).)

Binary fuse filters automatically deduplicate any keys during population. If you are using a different filter type (you probably shouldn't be!) then keys must be unique or else filter population will fail. You can use the `fastfilter.AutoUnique(u64)(keys)` helper to deduplicate (in typically O(N) time complexity), see the tests in `src/unique.zig` for usage examples.

## Serialization

To serialize the filters, you only need to encode these struct fields:

```zig
pub fn BinaryFuse(comptime T: type) type {
    return struct {
        ...
        seed: u64,
        segment_length: u32,
        segment_length_mask: u32,
        segment_count: u32,
        segment_count_length: u32,
        fingerprints: []T,
        ...
```

`T` will be the chosen fingerprint size, e.g. `u8` for `BinaryFuse8` or `Xor8`.

Look at [`std.io.Writer`](https://sourcegraph.com/github.com/ziglang/zig/-/blob/lib/std/io/writer.zig) and [`std.io.BitWriter`](https://sourcegraph.com/github.com/ziglang/zig/-/blob/lib/std/io/bit_writer.zig) for ideas on actual serialization.

Similarly, for xor filters you only need these struct fields:

```zig
pub fn Xor(comptime T: type) type {
    return struct {
        seed: u64,
        blockLength: u64,
        fingerprints: []T,
        ...
```

## Should I use binary fuse filters or xor filters?

If you're not sure, start with `BinaryFuse8` filters. They're fast, and have a false-positive probability rate of 1/256 (or 0.4%).

There are many tradeoffs, primarily between:

* Memory usage
* Containment check time
* Population / creation time & memory usage

See the [benchmarks](#benchmarks) section for a comparison of the tradeoffs between binary fuse filters and xor filters, as well as how larger bit sizes (e.g. `BinaryFuse(u16)`) consume more memory in exchange for a lower false-positive probability rate.

Note that _fuse filters_ are not to be confused with _binary fuse filters_, the former have issues with construction, often failing unless you have a large number of unique keys. Binary fuse filters do not suffer from this and are generally better than traditional ones in several ways. For this reason, we consider traditional fuse filters deprecated.

## Note about extremely large datasets

This implementation supports key iterators, so you do not need to have all of your keys in-memory, see `BinaryFuse8.populateIter` and `Xor8.populateIter`.

If you intend to use a xor filter with datasets of 100m+ keys, there is a possible faster implementation _for construction_ found in the C implementation [`xor8_buffered_populate`](https://github.com/FastFilter/xor_singleheader) which is not implemented here.

## Changelog

The API is generally finalized, but we may make some adjustments as Zig changes or we learn of more idiomatic ways to express things. We will release v1.0 once Zig v1.0 is released.

### **v0.12.0**
- Updated to the latest version of Zig 0.15.1

### **v0.11.0**

- fastfilter is now available via the Zig package manager.
- Updated to the latest version of Zig nightly `0.12.0-dev.706+62a0fbdae`

### **v0.10.3**

- Updated to the latest version of Zig `0.12.0-dev.706+62a0fbdae` (`build.zig` `.path` -> `.source` change.)

### **v0.10.2**

- Fixed a few correctness / integer overflow/underflow possibilities where we were inconsistent with the Go/C implementations of binary fuse filters.
- Added debug-mode checks for iterator correctness (wraparound behavior.)

### **v0.10.1**

- Updated to the latest version of Zig `0.12.0-dev.706+62a0fbdae`

### **v0.10.0**

- All types are now unmanaged (allocator must be passed via parameters)
- Renamed `util.sliceIterator` to `fastfilter.SliceIterator`
- `SliceIterator` is now unmanaged / does not store an allocator.
- `SliceIterator` now stores `[]const T` instead of `[]T` internally.
- `BinaryFuseFilter.max_iterations` is now a constant.
- Added `fastfilter.MeasuredAllocator` for measuring allocations.
- Improved usage example.
- Properly free xorfilter/fusefilter fingerprints.
- Updated benchmark to latest Zig version.

### **v0.9.3**

- Fixed potential integer overflow.

### **v0.9.2**

- Handle duplicated keys automatically
- Added a `std.build.Pkg` definition
- Fixed an unlikely bug
- Updated usage instructions
- Updated to Zig v0.10.0-dev.1736

### **v0.9.1**

- Updated to Zig v0.10.0-dev.36

### **v0.9.0**

- Renamed repository github.com/hexops/xorfilter -> github.com/hexops/fastfilter to account for binary fuse filters.
- Implemented bleeding-edge (paper not yet published) "Binary Fuse Filters: Fast and Smaller Than Xor Filters" algorithm by Thomas Mueller Graf, Daniel Lemire
- `BinaryFuse` filters are now recommended by default, are generally better than Xor and Fuse filters.
- Deprecated traditional `Fuse` filters (`BinaryFuse` are much better.)
- Added much improved benchmarking suite with more details on memory consumption during filter population, etc.

### **v0.8.0**

initial release with support for Xor and traditional Fuse filters of varying bit sizes, key iterators, serialization, and a slice de-duplication helper.

## Benchmarks

Benchmarks were ran on both a 2019 Macbook Pro and Windows 10 desktop machine using e.g.:

```
zig run -O ReleaseFast src/benchmark.zig -- --xor 8 --num-keys 1000000
```

<details>
<summary><strong>Benchmarks:</strong> 2019 Macbook Pro, Intel i9 (1M - 100M keys)</summary>

* CPU: 2.3 GHz 8-Core Intel Core i9
* Memory: 16 GB 2667 MHz DDR4
* Zig version: `0.12.0-dev.706+62a0fbdae`

| Algorithm    | # of keys  | populate   | contains(k) | false+ prob. | bits per entry | peak populate | filter total |
|--------------|------------|------------|-------------|--------------|----------------|---------------|--------------|
| binaryfuse8  | 1000000    |    37.5ms  |     24.0ns  |   0.00391115 |           9.04 |        22 MiB |        1 MiB |
| binaryfuse16 | 1000000    |    45.5ms  |     24.0ns  |   0.00001524 |          18.09 |        24 MiB |        2 MiB |
| binaryfuse32 | 1000000    |    56.0ms  |     24.0ns  |            0 |          36.18 |        28 MiB |        4 MiB |
| xor2         | 1000000    |   108.0ms  |     25.0ns  |    0.2500479 |           9.84 |        52 MiB |        1 MiB |
| xor4         | 1000000    |    99.0ms  |     25.0ns  |   0.06253865 |           9.84 |        52 MiB |        1 MiB |
| xor8         | 1000000    |   103.4ms  |     25.0ns  |    0.0039055 |           9.84 |        52 MiB |        1 MiB |
| xor16        | 1000000    |   104.7ms  |     26.0ns  |   0.00001509 |          19.68 |        52 MiB |        2 MiB |
| xor32        | 1000000    |   102.2ms  |     25.0ns  |            0 |          39.36 |        52 MiB |        4 MiB |
|              |            |            |             |              |                |               |              |
| binaryfuse8  | 10000000   |   621.2ms  |     36.0ns  |    0.0039169 |           9.02 |       225 MiB |       10 MiB |
| binaryfuse16 | 10000000   |   666.6ms  |    102.0ns  |    0.0000147 |          18.04 |       245 MiB |       21 MiB |
| binaryfuse32 | 10000000   |   769.0ms  |    135.0ns  |            0 |          36.07 |       286 MiB |       43 MiB |
| xor2         | 10000000   |     1.9s   |     43.0ns  |    0.2500703 |           9.84 |       527 MiB |       11 MiB |
| xor4         | 10000000   |     2.0s   |     41.0ns  |    0.0626137 |           9.84 |       527 MiB |       11 MiB |
| xor8         | 10000000   |     1.9s   |     42.0ns  |    0.0039369 |           9.84 |       527 MiB |       11 MiB |
| xor16        | 10000000   |     2.2s   |    106.0ns  |    0.0000173 |          19.68 |       527 MiB |       23 MiB |
| xor32        | 10000000   |     2.2s   |    140.0ns  |            0 |          39.36 |       527 MiB |       46 MiB |
|              |            |            |             |              |                |               |              |
| binaryfuse8  | 100000000  |     7.4s   |    145.0ns  |     0.003989 |           9.01 |         2 GiB |      107 MiB |
| binaryfuse16 | 100000000  |     8.4s   |    169.0ns  |     0.000016 |          18.01 |         2 GiB |      214 MiB |
| binaryfuse32 | 100000000  |    10.2s   |    173.0ns  |            0 |          36.03 |         2 GiB |      429 MiB |
| xor2         | 100000000  |    28.5s   |    144.0ns  |     0.249843 |           9.84 |         5 GiB |      117 MiB |
| xor4         | 100000000  |    27.4s   |    154.0ns  |     0.062338 |           9.84 |         5 GiB |      117 MiB |
| xor8         | 100000000  |    28.0s   |    153.0ns  |     0.004016 |           9.84 |         5 GiB |      117 MiB |
| xor16        | 100000000  |    29.5s   |    161.0ns  |     0.000012 |          19.68 |         5 GiB |      234 MiB |
| xor32        | 100000000  |    29.4s   |    157.0ns  |            0 |          39.36 |         5 GiB |      469 MiB |
|              |            |            |             |              |                |               |              |

Legend:

* **contains(k)**: The time taken to check if a key is in the filter
* **false+ prob.**: False positive probability, the probability that a containment check will erroneously return true for a key that has not actually been added to the filter.
* **bits per entry**: The amount of memory in bits the filter uses to store a single entry.
* **peak populate**: Amount of memory consumed during filter population, excluding keys themselves (8 bytes * num_keys.)
* **filter total**: Amount of memory consumed for filter itself in total (bits per entry * entries.)

</details>

<details>
<summary><strong>Benchmarks:</strong> Windows 10, AMD Ryzen 9 3900X (1M - 100M keys)</summary>

* CPU: 3.79Ghz AMD Ryzen 9 3900X
* Memory: 32 GB 2133 MHz DDR4
* Zig version: `0.12.0-dev.706+62a0fbdae`

| Algorithm    | # of keys  | populate   | contains(k) | false+ prob. | bits per entry | peak populate | filter total |
|--------------|------------|------------|-------------|--------------|----------------|---------------|--------------|
| binaryfuse8  | 1000000    |    44.6ms  |     24.0ns  |   0.00390796 |           9.04 |        22 MiB |        1 MiB |
| binaryfuse16 | 1000000    |    48.9ms  |     25.0ns  |   0.00001553 |          18.09 |        24 MiB |        2 MiB |
| binaryfuse32 | 1000000    |    49.9ms  |     25.0ns  |   0.00000001 |          36.18 |        28 MiB |        4 MiB |
| xor2         | 1000000    |    77.3ms  |     25.0ns  |   0.25000163 |           9.84 |        52 MiB |        1 MiB |
| xor4         | 1000000    |    80.0ms  |     25.0ns  |   0.06250427 |           9.84 |        52 MiB |        1 MiB |
| xor8         | 1000000    |    76.0ms  |     25.0ns  |   0.00391662 |           9.84 |        52 MiB |        1 MiB |
| xor16        | 1000000    |    83.7ms  |     26.0ns  |   0.00001536 |          19.68 |        52 MiB |        2 MiB |
| xor32        | 1000000    |    79.1ms  |     27.0ns  |            0 |          39.36 |        52 MiB |        4 MiB |
| fuse8        | 1000000    |    69.4ms  |     25.0ns  |   0.00390663 |           9.10 |        49 MiB |        1 MiB |
| fuse16       | 1000000    |    71.5ms  |     27.0ns  |   0.00001516 |          18.20 |        49 MiB |        2 MiB |
| fuse32       | 1000000    |    71.1ms  |     27.0ns  |            0 |          36.40 |        49 MiB |        4 MiB |
|              |            |            |             |              |                |               |              |
| binaryfuse8  | 10000000   |   572.3ms  |     33.0ns  |    0.0038867 |           9.02 |       225 MiB |       10 MiB |
| binaryfuse16 | 10000000   |   610.6ms  |    108.0ns  |    0.0000127 |          18.04 |       245 MiB |       21 MiB |
| binaryfuse32 | 10000000   |   658.2ms  |    144.0ns  |            0 |          36.07 |       286 MiB |       43 MiB |
| xor2         | 10000000   |     1.2s   |     39.0ns  |     0.249876 |           9.84 |       527 MiB |       11 MiB |
| xor4         | 10000000   |     1.2s   |     39.0ns  |    0.0625026 |           9.84 |       527 MiB |       11 MiB |
| xor8         | 10000000   |     1.2s   |     41.0ns  |    0.0038881 |           9.84 |       527 MiB |       11 MiB |
| xor16        | 10000000   |     1.3s   |    117.0ns  |    0.0000134 |          19.68 |       527 MiB |       23 MiB |
| xor32        | 10000000   |     1.3s   |    147.0ns  |            0 |          39.36 |       527 MiB |       46 MiB |
| fuse8        | 10000000   |     1.1s   |     36.0ns  |    0.0039089 |           9.10 |       499 MiB |       10 MiB |
| fuse16       | 10000000   |     1.1s   |    112.0ns  |    0.0000172 |          18.20 |       499 MiB |       21 MiB |
| fuse32       | 10000000   |     1.1s   |    145.0ns  |            0 |          36.40 |       499 MiB |       43 MiB |
|              |            |            |             |              |                |               |              |
| binaryfuse8  | 100000000  |     6.9s   |    167.0ns  |      0.00381 |           9.01 |         2 GiB |      107 MiB |
| binaryfuse16 | 100000000  |     7.2s   |    171.0ns  |     0.000009 |          18.01 |         2 GiB |      214 MiB |
| binaryfuse32 | 100000000  |     8.5s   |    174.0ns  |            0 |          36.03 |         2 GiB |      429 MiB |
| xor2         | 100000000  |    16.8s   |    166.0ns  |     0.249868 |           9.84 |         5 GiB |      117 MiB |
| xor4         | 100000000  |    18.9s   |    183.0ns  |     0.062417 |           9.84 |         5 GiB |      117 MiB |
| xor8         | 100000000  |    19.1s   |    168.0ns  |     0.003873 |           9.84 |         5 GiB |      117 MiB |
| xor16        | 100000000  |    16.9s   |    171.0ns  |     0.000021 |          19.68 |         5 GiB |      234 MiB |
| xor32        | 100000000  |    19.4s   |    189.0ns  |            0 |          39.36 |         5 GiB |      469 MiB |
| fuse8        | 100000000  |    19.6s   |    167.0ns  |     0.003797 |           9.10 |         4 GiB |      108 MiB |
| fuse16       | 100000000  |    20.8s   |    171.0ns  |     0.000015 |          18.20 |         4 GiB |      216 MiB |
| fuse32       | 100000000  |    21.5s   |    176.0ns  |            0 |          36.40 |         4 GiB |      433 MiB |
|              |            |            |             |              |                |               |              |

Legend:

* **contains(k)**: The time taken to check if a key is in the filter
* **false+ prob.**: False positive probability, the probability that a containment check will erroneously return true for a key that has not actually been added to the filter.
* **bits per entry**: The amount of memory in bits the filter uses to store a single entry.
* **peak populate**: Amount of memory consumed during filter population, excluding keys themselves (8 bytes * num_keys.)
* **filter total**: Amount of memory consumed for filter itself in total (bits per entry * entries.)

</details>

## Related readings

* Blog post by Daniel Lemire: [Xor Filters: Faster and Smaller Than Bloom Filters](https://lemire.me/blog/2019/12/19/xor-filters-faster-and-smaller-than-bloom-filters)
* Fuse Filters ([arxiv paper](https://arxiv.org/abs/1907.04749)), as described [by @jbapple](https://github.com/FastFilter/xor_singleheader/pull/11#issue-356508475) (note these are not to be confused with _binary fuse filters_.)

## Special thanks

* [**Thomas Mueller Graf**](https://github.com/thomasmueller) and [**Daniel Lemire**](https://github.com/lemire) - _for their excellent research into xor filters, xor+ filters, their C implementation, and more._
* [**Martin Dietzfelbinger**](https://arxiv.org/search/cs?searchtype=author&query=Dietzfelbinger%2C+M) and [**Stefan Walzer**](https://arxiv.org/search/cs?searchtype=author&query=Walzer%2C+S) - _for their excellent research into fuse filters._
* [**Jim Apple**](https://github.com/jbapple) - _for their C implementation[[1]](https://github.com/FastFilter/xor_singleheader/pull/11) of fuse filters_
* [**@Andoryuuta**](https://github.com/Andoryuuta) - _for providing substantial help in debugging several issues in the Zig implementation._

If it was not for the above people, I ([@emidoots](https://github.com/emidoots)) would not have been able to write this implementation and learn from the excellent [C implementation](https://github.com/FastFilter/xor_singleheader). Please credit the above people if you use this library.
