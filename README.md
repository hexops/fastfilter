# xorfilter: Zig implementation of Xor Filters <a href="https://hexops.com"><img align="right" alt="Hexops logo" src="https://raw.githubusercontent.com/hexops/media/main/readme.svg"></img></a>

[![CI](https://github.com/hexops/xorfilter/workflows/CI/badge.svg)](https://github.com/hexops/xorfilter/actions)

This is a [Zig](https://ziglang.org) implementation of Xor Filters and Fuse Filters, which are faster and smaller than Bloom and Cuckoo filters and allow for quickly checking if a key is part of a set.

- [Benefits of Zig implementation](#benefits-of-zig-implementation)
- [Research papers](#research-papers)
- [Usage](#usage)
- [Serialization](#serialization)
- [Note about extremely large datasets](#note-about-extremely-large-datasets)
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
<summary><strong>Benchmarks:</strong> 2019 Macbook Pro (1M - 100M keys)</summary>

* CPU: 2.3Ghz Intel Core i9
* Memory: 16 GB 2667 MHz DDR4
* Zig version: ``0.8.0-dev.1032+8098b3f84`

| Algorithm | # of keys | populate | time per containment check | fpp (estimated) | bits per entry (memory) |
|-----------|-----------|----------|----------------------------|-----------------|-------------------------|
| xor4      | 1M        | 92ms     | 28ns/check                 | 0.0625333000    | 9.8                     |
| xor8      | 1M        | 124ms    | 29ns/check                 | 0.0039010000    | 9.8                     |
| xor16     | 1M        | 106ms    | 30ns/check                 | 0.0000140000    | 19.7                    |
| xor32     | 1M        | 99ms     | 33ns/check                 | 0.0000000000    | 39.4                    |
| fuse8     | 1M        | 96ms     | 28ns/check                 | 0.0039010000    | 9.8                     |
| fuse16    | 1M        | 93ms     | 30ns/check                 | 0.0000140000    | 19.7                    |
|           |           |          |                            |                 |                         |
| xor4      | 10M       | 1.6s     | 90ns/check                 | 0.0626137000    | 9.8                     |
| xor8      | 10M       | 1.6s     | 89ns/check                 | 0.0039369000    | 9.8                     |
| xor16     | 10M       | 1.6s     | 105ns/check                | 0.0000173000    | 19.7                    |
| xor32     | 10M       | 1.6s     | 119ns/check                | 0.0000000000    | 39.4                    |
| fuse8     | 10M       | 1.6s     | 92ns/check                 | 0.0039369000    | 9.8                     |
| fuse16    | 10M       | 1.6s     | 113ns/check                | 0.0000173000    | 19.7                    |
|           |           |          |                            |                 |                         |
| xor4      | 100M      | 23s      | 128ns/check                | 0.0625772000    | 9.8                     |
| xor8      | 100M      | 20s      | 125ns/check                | 0.0039238000    | 9.8                     |
| xor16     | 100M      | 21s      | 136ns/check                | 0.0000147000    | 19.7                    |
| xor32     | 100M      | 22s      | 135ns/check                | 0.0000000000    | 39.4                    |
| fuse8     | 100M      | 21s      | 124ns/check                | 0.0039238000    | 9.8                     |
| fuse16    | 100M      | 22s      | 126ns/check                | 0.0000147000    | 19.7                    |

</details>

<details>
<summary><strong>Benchmarks:</strong> Windows 10 WSL2 Desktop (1M - 250M keys)</summary>

* CPU: 3.79Ghz AMD Ryzen 9 3900X
* Memory: 32 GB 2133 MHz DDR4
* Zig version: ``0.8.0-dev.1039+bea791b63`

| Algorithm | # of keys | populate | time per containment check | fpp (estimated) | bits per entry (memory) |
|-----------|-----------|----------|----------------------------|-----------------|-------------------------|
| xor4      | 1M        | 112ms    | 23ns/check                 | 0.0625333000    | 9.8                     |
| xor8      | 1M        | 112ms    | 23ns/check                 | 0.0039010000    | 9.8                     |
| xor16     | 1M        | 117ms    | 24ns/check                 | 0.0000140000    | 19.7                    |
| xor32     | 1M        | 119ms    | 25ns/check                 | 0.0000000000    | 39.4                    |
| fuse8     | 1M        | 112ms    | 23ns/check                 | 0.0039010000    | 9.8                     |
| fuse16    | 1M        | 115ms    | 24ns/check                 | 0.0000140000    | 19.7                    |
|           |           |          |                            |                 |                         |
| xor4      | 10M       | 1.6s     | 39ns/check                 | 0.0626137000    | 9.8                     |
| xor8      | 10M       | 1.6s     | 38ns/check                 | 0.0039369000    | 9.8                     |
| xor16     | 10M       | 1.7s     | 126ns/check                | 0.0000173000    | 19.7                    |
| xor32     | 10M       | 1.8s     | 158ns/check                | 0.0000000000    | 39.4                    |
| fuse8     | 10M       | 1.6s     | 38ns/check                 | 0.0039369000    | 9.8                     |
| fuse16    | 10M       | 1.7s     | 127ns/check                | 0.0000173000    | 19.7                    |
|           |           |          |                            |                 |                         |
| xor4      | 100M      | 21s      | 175ns/check                | 0.0625772000    | 9.8                     |
| xor8      | 100M      | 20s      | 175ns/check                | 0.0039238000    | 9.8                     |
| xor16     | 100M      | 20s      | 180ns/check                | 0.0000147000    | 19.7                    |
| xor32     | 100M      | 20s      | 190ns/check                | 0.0000000000    | 39.4                    |
| fuse8     | 100M      | 20s      | 181ns/check                | 0.0039238000    | 9.8                     |
| fuse16    | 100M      | 20s      | 183ns/check                | 0.0000147000    | 19.7                    |
|           |           |          |                            |                 |                         |
| xor4      | 250M      | 1.1min   | 194ns/check                | 0.0625503000    | 9.8                     |
| xor8      | 250M      | 1.2min   | 190ns/check                | 0.0038876000    | 9.8                     |
| xor16     | 250M      | 1.2min   | 196ns/check                | 0.0000125000    | 19.7                    |
| xor32     | 250M      | 1.1min   | 203ns/check                | 0.0000000000    | 39.4                    |
| fuse8     | 250M      | 1.1min   | 199ns/check                | 0.0038876000    | 9.8                     |
| fuse16    | 250M      | 1.1min   | 203ns/check                | 0.0000125000    | 19.7                    |

</details>

## Special thanks

* [**Thomas Mueller Graf**](https://github.com/thomasmueller) and [**Daniel Lemire**](https://github.com/lemire) - _for their excellent research into xor filters, xor+ filters, their C implementation, and more._
* [**Martin Dietzfelbinger**](https://arxiv.org/search/cs?searchtype=author&query=Dietzfelbinger%2C+M) and [**Stefan Walzer**](https://arxiv.org/search/cs?searchtype=author&query=Walzer%2C+S) - _for their excellent research into fuse filters._
* [**Jim Apple**](https://github.com/jbapple) - _for their C implementation[[1]](https://github.com/FastFilter/xor_singleheader/pull/11) of fuse filters_
* [**Andrew Gutekanst**](https://github.com/Andoryuuta) - _for providing substantial help in debugging several issues in the Zig implementation._

If it was not for the above people, I ([@slimsag](https://github.com/slimsag)) would not have been able to write this implementation and learn from the excellent [C implementation](https://github.com/FastFilter/xor_singleheader). Please credit the above people if you use this library.

## Changelog

The API is generally finalized, but we may make some adjustments as Zig changes or we learn of more idiomatic ways to express things. We will release v1.0 once Zig v1.0 is released.

- **v0.8.0**: initial release with support for Xor and Fuse filters of varying bit sizes, key iterators, serialization, and a slice de-duplication helper.
