# xorfilter: Zig implementation of Xor Filters <a href="https://hexops.com"><img align="right" alt="Hexops logo" src="https://raw.githubusercontent.com/hexops/media/main/readme.svg"></img></a>

[![CI](https://github.com/hexops/xorfilter/workflows/CI/badge.svg)](https://github.com/hexops/xorfilter/actions)

This is a [Zig](https://ziglang.org) implementation of Xor Filters, which are faster and smaller than Bloom and Cuckoo filters and allow for quickly checking if a key is part of a set.

The implementation provides:

* xor8 (recommended, has no more than a 0.3% false-positive probability)
* xor16
* xor32, xor64 (rarely needed)
* fuse8 (better than xor+ variants when you have > 100 million keys)

Thanks to Zig's [bit-width integers](https://ziglang.org/documentation/master/#Runtime-Integer-Values) and type system, this implementation is also able to support more specific variants of xor filters like xor4, xor6, xor10, xor12, or any other log2 bit size for xor keys via e.g. `Xor(u4)`. This can be interesting if you care about serialization size (but not memory, as Zig represents `u4` as a full byte.)

## Research

Blog post: [Xor Filters: Faster and Smaller Than Bloom Filters](https://lemire.me/blog/2019/12/19/xor-filters-faster-and-smaller-than-bloom-filters).

Xor Filters ([arxiv paper](https://arxiv.org/abs/1912.08258)):

> Thomas Mueller Graf, Daniel Lemire, Xor Filters: Faster and Smaller Than Bloom and Cuckoo Filters, Journal of Experimental Algorithmics 25 (1), 2020. DOI: 10.1145/3376122 

Fuse Filters ([arxiv paper](https://arxiv.org/abs/1907.04749)), as described [by @jbapple](https://github.com/FastFilter/xor_singleheader/pull/11#issue-356508475):

> For large enough sets of keys, Dietzfelbinger & Walzer's fuse filters,
described in "Dense Peelable Random Uniform Hypergraphs", can accomodate fill factors up to 87.9% full, rather than 1 / 1.23 = 81.3%.

## Usage

1. Decide if you want to use `Xor8` or `Fuse8` (you probably want `Xor8`): ["Should I use xor filters or fuse filters?"](#should-i-use-xor-filters-or-fuse-filters).
2. Convert your keys into `u64` values. If you have strings, structs, etc. then use something like Zig's [`std.hash_map.getAutoHashFn`](https://ziglang.org/documentation/master/std/#std;hash_map.getAutoHashFn) to convert your keys to `u64` first.
3. Your keys must be unique, or else filter construction will fail. If you don't have unique keys, you can use the `xorfilter.AutoUnique(u64)(keys)` helper to deduplicate in typically O(N) time complexity, see the tests in `src/unique.zig` for more info.

Here is an example:

```zig
const xorfilter = @import("../xorfilter/src/main.zig")

test "mytest" {
    const allocator = std.heap.page_allocator;

    // Initialize the xor filter with room for 10000 keys.
    const size = 10000; // room for 10000 keys
    const filter = try xorfilter.Xor8.init(allocator, size);
    defer filter.deinit(allocator);

    // Generate some consecutive keys.
    var keys = try allocator.alloc(u64, size);
    defer allocator.free(keys);
    for (keys) |key, i| {
        keys[i] = i;
    }

    // If your keys are not unique, make them so:
    keys = xorfilter.Unique(u64)(keys);

    // If this fails, your keys are not unique.
    var success = try filter.populate(allocator, keys[0..]);
    testing.expect(success == true);

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

## Special thanks

* [**Thomas Mueller Graf**](https://github.com/thomasmueller) and [**Daniel Lemire**](https://github.com/lemire) - _for their excellent research into xor filters, xor+ filters, their C implementation, and more._
* [**Martin Dietzfelbinger**](https://arxiv.org/search/cs?searchtype=author&query=Dietzfelbinger%2C+M) and [**Stefan Walzer**](https://arxiv.org/search/cs?searchtype=author&query=Walzer%2C+S) - _for their excellent research into fuse filters._
* [**Jim Apple**](https://github.com/jbapple) - _for their C implementation[[1]](https://github.com/FastFilter/xor_singleheader/pull/11) of fuse filters_
* [**Andrew Gutekanst**](https://github.com/Andoryuuta) - _for providing substantial help in debugging several issues in the Zig implementation._

If it was not for the above people, I ([@slimsag](https://github.com/slimsag)) would not have been able to write this implementation and learn from the excellent [C implementation](https://github.com/FastFilter/xor_singleheader). Please credit the above people if you use this library.
