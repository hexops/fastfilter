# xorfilter: Zig implementation of Xor Filters <a href="https://hexops.com"><img align="right" alt="Hexops logo" src="https://raw.githubusercontent.com/hexops/media/main/readme.svg"></img></a>

[![CI](https://github.com/hexops/xorfilter/workflows/CI/badge.svg)](https://github.com/hexops/xorfilter/actions)

This is an idiomatic Zig implementation of Xor Filters ([arxiv paper](https://arxiv.org/abs/1912.08258)):

> Thomas Mueller Graf, Daniel Lemire, Xor Filters: Faster and Smaller Than Bloom and Cuckoo Filters, Journal of Experimental Algorithmics 25 (1), 2020. DOI: 10.1145/3376122

Blog post: [Xor Filters: Faster and Smaller Than Bloom Filters](https://lemire.me/blog/2019/12/19/xor-filters-faster-and-smaller-than-bloom-filters).

As well as Fuse Filters ([arxiv paper](https://arxiv.org/abs/1907.04749)):

> For large enough sets of keys, Dietzfelbinger & Walzer's fuse filters,
described in "Dense Peelable Random Uniform Hypergraphs", can accomodate fill factors up to 87.9% full, rather than 1 / 1.23 = 81.3%.

Which, as I understand, are a more compressible / optimal alternative to the xor+ algorithm with large sets of keys [[1]](https://github.com/FastFilter/xor_singleheader/pull/11) [[2]](https://github.com/FastFilter/fastfilter_java/issues/21) [[3]](https://github.com/FastFilter/xorfilter/issues/5#issuecomment-569121442))

## Supported algorithms

This implementation supports a handful of filter algorithms:

- xor8
- xor16
- fuse8

Additionally, thanks to Zig's generics it is possible to use use any integral type for the xor filter's fingerprint bit sizes, e.g. xor2, xor4, xor32, xor64, etc. are all possible - as well as their map counterparts, something that [is hard to support in the C implementation](https://github.com/FastFilter/xor_singleheader/issues/8).

## Credits

Special thanks go to:

* Thomas Mueller Graf ([@thomasmueller](https://github.com/thomasmueller)) and Daniel Lemire ([@lemire](https://github.com/lemire)), University of Quebec (TELUQ), Canada - _for their excellent research into xor filters, xor+ filters, their C implementation, and more._
* [Martin Dietzfelbinger](https://arxiv.org/search/cs?searchtype=author&query=Dietzfelbinger%2C+M) and [Stefan Walzer](https://arxiv.org/search/cs?searchtype=author&query=Walzer%2C+S), Technische Universität Ilmenau, Germany - _for their excellent research into fuse filters._
* Jim Apple ([@jbapple](https://github.com/jbapple)) - _for their C implementation[[1]](https://github.com/FastFilter/xor_singleheader/pull/11) of fuse filters_
* Andrew Gutekanst ([@Andoryuuta](https://github.com/Andoryuuta)), for providing substantial help in debugging several issues in the Zig implementation with their RE skills.

Stephen Gutekanst ([@slimsag](https://github.com/slimsag)) authored this Zig implementation, and drew heavy inspiration from the original author's [C single-header](https://github.com/FastFilter/xor_singleheader) implementation. Please credit the above people if you use this library, as I would not have been able to write this implementation if not for their amazing work.
