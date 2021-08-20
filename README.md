# xorfilter: Zig implementation of Xor Filters <a href="https://hexops.com"><img align="right" alt="Hexops logo" src="https://raw.githubusercontent.com/hexops/media/main/readme.svg"></img></a>

[![CI](https://github.com/hexops/xorfilter/workflows/CI/badge.svg)](https://github.com/hexops/xorfilter/actions)

This is a [Zig](https://ziglang.org) implementation of Xor Filters and Fuse Filters, which are faster and smaller than Bloom and Cuckoo filters and allow for quickly checking if a key is part of a set.

- [xorfilter: Zig implementation of Xor Filters <a href="https://hexops.com"><img align="right" alt="Hexops logo" src="https://raw.githubusercontent.com/hexops/media/main/readme.svg"></img></a>](#xorfilter-zig-implementation-of-xor-filters-img)
  - [Benefits of Zig implementation](#benefits-of-zig-implementation)
  - [Research papers](#research-papers)
  - [Usage](#usage)
  - [Serialization](#serialization)
  - [Should I use xor filters or fuse filters?](#should-i-use-xor-filters-or-fuse-filters)
  - [Note about extremely large datasets](#note-about-extremely-large-datasets)
  - [Benchmarks](#benchmarks)
  - [Special thanks](#special-thanks)
  - [Changelog](#changelog)

## Benefits of Zig implementation

The two primary algorithms of interest here are:

* `Xor8` (recommended, has no more than a 0.3% false-positive probability)
* `Fuse8` (better than xor+ variants when you have > 100 million keys)

Thanks to Zig's [bit-width integers](https://ziglang.org/documentation/master/#Runtime-Integer-Values) and type system, many more bit variants - any that is log2 - is supported as well via e.g. `Xor(u4)` or `Fuse(u4)`:

* xor4, xor16, xor32, xor64, etc.
* fuse4, fuse16, etc.

Note, however, that Zig represents e.g. `u4` as a full byte. The more exotic bit-widths `u4`, `u20`, etc. are primarily interesting for [more compact serialization](#serialization).

## Research papers

Blog post: [Xor Filters: Faster and Smaller Than Bloom Filters](https://lemire.me/blog/2019/12/19/xor-filters-faster-and-smaller-than-bloom-filters).

Xor Filters ([arxiv paper](https://arxiv.org/abs/1912.08258)):

> Thomas Mueller Graf, Daniel Lemire, Xor Filters: Faster and Smaller Than Bloom and Cuckoo Filters, Journal of Experimental Algorithmics 25 (1), 2020. DOI: 10.1145/3376122 

Fuse Filters ([arxiv paper](https://arxiv.org/abs/1907.04749)), as described [by @jbapple](https://github.com/FastFilter/xor_singleheader/pull/11#issue-356508475):

> For large enough sets of keys, Dietzfelbinger & Walzer's fuse filters,
described in "Dense Peelable Random Uniform Hypergraphs", can accomodate fill factors up to 87.9% full, rather than 1 / 1.23 = 81.3%.

## Usage

1. Decide if you want to use `Xor8` or `Fuse8` (you probably want `Xor8`): ["Should I use xor filters or fuse filters?"](#should-i-use-xor-filters-or-fuse-filters).
2. Convert your keys into `u64` values. If you have strings, structs, etc. then use something like Zig's [`std.hash_map.getAutoHashFn`](https://ziglang.org/documentation/master/std/#std;hash_map.getAutoHashFn) to convert your keys to `u64` first. "It is not important to have a good hash function, but collisions should be unlikely (~1/2^64)."
3. Your keys must be unique, or else filter construction will fail. If you don't have unique keys, you can use the `xorfilter.AutoUnique(u64)(keys)` helper to deduplicate in typically O(N) time complexity, see the tests in `src/unique.zig` for more info.

Here is an example:

```zig
const xorfilter = @import("../xorfilter/src/main.zig")

test "mytest" {
    const allocator = std.heap.page_allocator;

    // Initialize the xor filter with room for 10000 keys.
    const size = 10000; // room for 10000 keys
    const filter = try xorfilter.Xor8.init(allocator, size);
    defer filter.deinit();

    // Generate some consecutive keys.
    var keys = try allocator.alloc(u64, size);
    defer allocator.free(keys);
    for (keys) |key, i| {
        keys[i] = i;
    }

    // If your keys are not unique, make them so:
    keys = xorfilter.Unique(u64)(keys);

    // If this fails, your keys are not unique or allocation failed.
    try filter.populate(allocator, keys[0..]);

    // Now we can quickly test for containment!
    testing.expect(filter.contain(1) == true);
}
```

(you can just add this project as a Git submodule in yours for now, as [Zig's official package manager is still under way](https://github.com/ziglang/zig/issues/943).)

## Serialization

To serialize the filters, you only need to encode the three struct fields:

```zig
pub fn Xor(comptime T: type) type {
    return struct {
        seed: u64,
        blockLength: u64,
        fingerprints: []T,
...
```

`T` will be the chosen fingerprint size, e.g. `u8` for `Xor8`.

Look at [`std.io.Writer`](https://sourcegraph.com/github.com/ziglang/zig/-/blob/lib/std/io/writer.zig) and [`std.io.BitWriter`](https://sourcegraph.com/github.com/ziglang/zig/-/blob/lib/std/io/bit_writer.zig) for ideas on actual serialization.

(The same is true of the fuse filter, replacing `blockLength` with `segmentLength`.)

## Should I use xor filters or fuse filters?

Xor8 is the recommended default, and has no more than a 0.3% false-positive probability. If you have > 100 million keys, fuse8 may be better.

My _non-expert_ understanding is that fuse filters are more compressed and optimal than **xor+** filters with extremely large sets of keys based on[[1]](https://github.com/FastFilter/xor_singleheader/pull/11)[[2]](https://github.com/FastFilter/fastfilter_java/issues/21)[[3]](https://github.com/FastFilter/xorfilter/issues/5#issuecomment-569121442). You should use them in place of xor+, and refer to the xor filter paper for whether or not you are at a scale that requires xor+/fuse filters.

**Note that the fuse filter algorithm does require a large number of unique keys in order for population to succeed**, see [FastFilter/xor_singleheader#21](https://github.com/FastFilter/xor_singleheader/issues/21) - if you have few (<~125k consecutive) keys creation will fail.

## Note about extremely large datasets

This implementation supports key iterators, so you do not need to have all of your keys in-memory, see `Xor8.populateIter` and `Fuse8.populateIter`.

If you intend to use a xor filter with datasets of 100m+ keys, there is a possible faster implementation _for construction_ found in the C implementation [`xor8_buffered_populate`](https://github.com/FastFilter/xor_singleheader) which is not _yet_ implemented here.

## Benchmarks

Benchmarks were ran on both a 2019 Macbook Pro and Windows 10 (WSL2) desktop machine using e.g.:

```
zig run -O ReleaseFast src/benchmark.zig -- --xor 8 --num-keys 1000000
```

<details>
<summary><strong>Benchmarks:</strong> 2019 Macbook Pro, Intel i9 (1M - 100M keys)</summary>

* CPU: 2.3 GHz 8-Core Intel Core i9
* Memory: 16 GB 2667 MHz DDR4
* Zig version: `0.9.0-dev.369+254a35fd8`

| Algorithm  | # of keys  | populate   | contains(k) | false+ prob. | bits per entry | peak populate | filter total |
|------------|------------|------------|-------------|--------------|----------------|---------------|--------------|
| xor2       | 1000000    |   106.4ms  |     25.0ns  |    0.2500479 |           9.84 |        52 MiB |        1 MiB |
| xor4       | 1000000    |    97.7ms  |     25.0ns  |   0.06253865 |           9.84 |        52 MiB |        1 MiB |
| xor8       | 1000000    |    99.8ms  |     26.0ns  |    0.0039055 |           9.84 |        52 MiB |        1 MiB |
| xor16      | 1000000    |    98.2ms  |     25.0ns  |   0.00001509 |          19.68 |        52 MiB |        2 MiB |
| xor32      | 1000000    |   105.2ms  |     26.0ns  |            0 |          39.36 |        52 MiB |        4 MiB |
| fuse8      | 1000000    |    81.7ms  |     25.0ns  |   0.00390901 |           9.10 |        49 MiB |        1 MiB |
| fuse16     | 1000000    |    85.5ms  |     26.0ns  |    0.0000147 |          18.20 |        49 MiB |        2 MiB |
| fuse32     | 1000000    |    88.9ms  |     26.0ns  |            0 |          36.40 |        49 MiB |        4 MiB |
|            |            |            |             |              |                |               |              |
| xor2       | 10000000   |     1.7s   |     49.0ns  |    0.2500703 |           9.84 |       527 MiB |       11 MiB |
| xor4       | 10000000   |     2.0s   |     45.0ns  |    0.0626137 |           9.84 |       527 MiB |       11 MiB |
| xor8       | 10000000   |     2.0s   |     48.0ns  |    0.0039369 |           9.84 |       527 MiB |       11 MiB |
| xor16      | 10000000   |     2.1s   |    109.0ns  |    0.0000173 |          19.68 |       527 MiB |       23 MiB |
| xor32      | 10000000   |     2.2s   |    144.0ns  |            0 |          39.36 |       527 MiB |       46 MiB |
| fuse8      | 10000000   |     1.5s   |     38.0ns  |    0.0039017 |           9.10 |       499 MiB |       10 MiB |
| fuse16     | 10000000   |     1.5s   |    104.0ns  |    0.0000174 |          18.20 |       499 MiB |       21 MiB |
| fuse32     | 10000000   |     1.5s   |    137.0ns  |            0 |          36.40 |       499 MiB |       43 MiB |
|            |            |            |             |              |                |               |              |
| xor2       | 100000000  |    27.6s   |    138.0ns  |     0.249843 |           9.84 |         5 GiB |      117 MiB |
| xor4       | 100000000  |    27.9s   |    159.0ns  |     0.062338 |           9.84 |         5 GiB |      117 MiB |
| xor8       | 100000000  |    27.8s   |    124.0ns  |     0.004016 |           9.84 |         5 GiB |      117 MiB |
| xor16      | 100000000  |    29.5s   |    184.0ns  |     0.000012 |          19.68 |         5 GiB |      234 MiB |
| xor32      | 100000000  |    31.5s   |    212.0ns  |            0 |          39.36 |         5 GiB |      469 MiB |
| fuse8      | 100000000  |    23.4s   |    130.0ns  |     0.003887 |           9.10 |         4 GiB |      108 MiB |
| fuse16     | 100000000  |    24.5s   |    133.0ns  |     0.000014 |          18.20 |         4 GiB |      216 MiB |
| fuse32     | 100000000  |    25.5s   |    165.0ns  |            0 |          36.40 |         4 GiB |      433 MiB |
|            |            |            |             |              |                |               |              |

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
* Zig version: `0.9.0-dev.450+aa2a31612`

| Algorithm  | # of keys  | populate   | contains(k) | false+ prob. | bits per entry | peak populate | filter total |
|------------|------------|------------|-------------|--------------|----------------|---------------|--------------|
| xor2       | 1000000    |    74.5ms  |     25.0ns  |   0.25000163 |           9.84 |        52 MiB |        1 MiB |
| xor4       | 1000000    |    84.4ms  |     25.0ns  |   0.06250427 |           9.84 |        52 MiB |        1 MiB |
| xor8       | 1000000    |    73.8ms  |     25.0ns  |   0.00391662 |           9.84 |        52 MiB |        1 MiB |
| xor16      | 1000000    |    75.9ms  |     25.0ns  |   0.00001536 |          19.68 |        52 MiB |        2 MiB |
| xor32      | 1000000    |    76.1ms  |     25.0ns  |            0 |          39.36 |        52 MiB |        4 MiB |
| fuse8      | 1000000    |    65.3ms  |     24.0ns  |   0.00390663 |           9.10 |        49 MiB |        1 MiB |
| fuse16     | 1000000    |    68.3ms  |     25.0ns  |   0.00001516 |          18.20 |        49 MiB |        2 MiB |
| fuse32     | 1000000    |    70.2ms  |     26.0ns  |            0 |          36.40 |        49 MiB |        4 MiB |
|            |            |            |             |              |                |               |              |
| xor2       | 10000000   |     1.1s   |     35.0ns  |     0.249876 |           9.84 |       527 MiB |       11 MiB |
| xor4       | 10000000   |     1.1s   |     37.0ns  |    0.0625026 |           9.84 |       527 MiB |       11 MiB |
| xor8       | 10000000   |     1.1s   |     35.0ns  |    0.0038881 |           9.84 |       527 MiB |       11 MiB |
| xor16      | 10000000   |     1.3s   |    114.0ns  |    0.0000134 |          19.68 |       527 MiB |       23 MiB |
| xor32      | 10000000   |     1.3s   |    144.0ns  |            0 |          39.36 |       527 MiB |       46 MiB |
| fuse8      | 10000000   |     1.0s   |     34.0ns  |    0.0039089 |           9.10 |       499 MiB |       10 MiB |
| fuse16     | 10000000   |     1.0s   |    106.0ns  |    0.0000172 |          18.20 |       499 MiB |       21 MiB |
| fuse32     | 10000000   |     1.1s   |    142.0ns  |            0 |          36.40 |       499 MiB |       43 MiB |
|            |            |            |             |              |                |               |              |
| xor2       | 100000000  |    20.2s   |    166.0ns  |     0.249868 |           9.84 |         5 GiB |      117 MiB |
| xor4       | 100000000  |    20.2s   |    167.0ns  |     0.062417 |           9.84 |         5 GiB |      117 MiB |
| xor8       | 100000000  |    19.2s   |    166.0ns  |     0.003873 |           9.84 |         5 GiB |      117 MiB |
| xor16      | 100000000  |    17.9s   |    169.0ns  |     0.000021 |          19.68 |         5 GiB |      234 MiB |
| xor32      | 100000000  |    20.3s   |    181.0ns  |            0 |          39.36 |         5 GiB |      469 MiB |
| fuse8      | 100000000  |    20.6s   |    166.0ns  |     0.003797 |           9.10 |         4 GiB |      108 MiB |
| fuse16     | 100000000  |    21.6s   |    170.0ns  |     0.000015 |          18.20 |         4 GiB |      216 MiB |
| fuse32     | 100000000  |    21.4s   |    174.0ns  |            0 |          36.40 |         4 GiB |      433 MiB |
|            |            |            |             |              |                |               |              |

Legend:

* **contains(k)**: The time taken to check if a key is in the filter
* **false+ prob.**: False positive probability, the probability that a containment check will erroneously return true for a key that has not actually been added to the filter.
* **bits per entry**: The amount of memory in bits the filter uses to store a single entry.
* **peak populate**: Amount of memory consumed during filter population, excluding keys themselves (8 bytes * num_keys.)
* **filter total**: Amount of memory consumed for filter itself in total (bits per entry * entries.)

</details>

## Special thanks

* [**Thomas Mueller Graf**](https://github.com/thomasmueller) and [**Daniel Lemire**](https://github.com/lemire) - _for their excellent research into xor filters, xor+ filters, their C implementation, and more._
* [**Martin Dietzfelbinger**](https://arxiv.org/search/cs?searchtype=author&query=Dietzfelbinger%2C+M) and [**Stefan Walzer**](https://arxiv.org/search/cs?searchtype=author&query=Walzer%2C+S) - _for their excellent research into fuse filters._
* [**Jim Apple**](https://github.com/jbapple) - _for their C implementation[[1]](https://github.com/FastFilter/xor_singleheader/pull/11) of fuse filters_
* [**Andrew Gutekanst**](https://github.com/Andoryuuta) - _for providing substantial help in debugging several issues in the Zig implementation._

If it was not for the above people, I ([@slimsag](https://github.com/slimsag)) would not have been able to write this implementation and learn from the excellent [C implementation](https://github.com/FastFilter/xor_singleheader). Please credit the above people if you use this library.

## Changelog

The API is generally finalized, but we may make some adjustments as Zig changes or we learn of more idiomatic ways to express things. We will release v1.0 once Zig v1.0 is released.

- **v0.9.0** (not yet published):
  - Added much improved benchmarking suite with more details on memory consumption during filter population, etc.
  - Properly exposed the `Fuse(T)` type, for arbitrary-bit-size fuse filters.
- **v0.8.0**: initial release with support for Xor and Fuse filters of varying bit sizes, key iterators, serialization, and a slice de-duplication helper.
