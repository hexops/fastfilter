# xorfilter: Zig implementation of Xor Filters <a href="https://hexops.com"><img align="right" alt="Hexops logo" src="https://raw.githubusercontent.com/hexops/media/main/readme.svg"></img></a>

[![CI](https://github.com/hexops/xorfilter/workflows/CI/badge.svg)](https://github.com/hexops/xorfilter/actions)

This is an idiomatic Zig implementation of Xor Filters:

- Blog post: [Xor Filters: Faster and Smaller Than Bloom Filters](https://lemire.me/blog/2019/12/19/xor-filters-faster-and-smaller-than-bloom-filters).
- Paper (arxiv): [Xor Filters: Faster and Smaller Than Bloom and Cuckoo Filters](https://arxiv.org/abs/1912.08258)

The implementation is originally ported from the original authors' [C single-header](https://github.com/FastFilter/xor_singleheader) version, which appeared to be the most efficient implementation - and then made into idiomatic Zig.
