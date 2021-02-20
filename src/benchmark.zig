// zig run -O ReleaseFast src/benchmark.zig -- --xor 8 --num-keys 1000000 --num-trials 10000000

const std = @import("std");
const time = std.time;
const Timer = time.Timer;
const xorfilter = @import("main.zig");

fn formatTime(writer: anytype, start: u64, end: u64, division: usize) !void {
    const ns = @intToFloat(f64, (end - start) / division);
    if (ns <= time.ns_per_ms) {
        try std.fmt.format(writer, "{d:.3}ns", .{ns});
        return;
    }
    if (ns <= time.ns_per_s) {
        try std.fmt.format(writer, "{d:.3}ms", .{ns / @intToFloat(f64, time.ns_per_ms)});
        return;
    }
    if (ns <= time.ns_per_min) {
        try std.fmt.format(writer, "{d:.3}s", .{ns / @intToFloat(f64, time.ns_per_s)});
        return;
    }
    try std.fmt.format(writer, "{d:.3}min", .{ns / @intToFloat(f64, time.ns_per_min)});
    return;
}

fn xorBench(T: anytype, size: usize, trials: usize) !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();
    var timer = try Timer.start();

    // Initialize filter.
    var start = timer.lap();
    const filter = try xorfilter.Xor(T).init(allocator, size);
    defer filter.deinit();
    var end = timer.read();
    try stdout.print("init:\t", .{});
    try formatTime(stdout, start, end, 1);
    try stdout.print("\n", .{});

    // Generate keys.
    timer.reset();
    start = timer.lap();
    var keys = try allocator.alloc(u64, size);
    defer allocator.free(keys);
    for (keys) |key, i| {
        keys[i] = i;
    }
    end = timer.read();
    try stdout.print("generate keys:\t", .{});
    try formatTime(stdout, start, end, 1);
    try stdout.print("\n", .{});

    // Populate filter.
    timer.reset();
    start = timer.lap();
    try filter.populate(allocator, keys[0..]);
    end = timer.read();
    try stdout.print("populate:\t", .{});
    try formatTime(stdout, start, end, 1);
    try stdout.print("\n", .{});

    // Perform random matches.
    var random_matches: u64 = 0;
    var i: u64 = 0;
    var default_prng = std.rand.DefaultPrng.init(0);
    timer.reset();
    start = timer.lap();
    while (i < trials) : (i += 1) {
        var random_key: u64 = default_prng.random.uintAtMost(u64, std.math.maxInt(u64));
        if (filter.contain(random_key)) {
            if (random_key >= keys.len) {
                random_matches += 1;
            }
        }
    }
    end = timer.read();
    try stdout.print("random matches:\t", .{});
    try formatTime(stdout, start, end, trials);
    try stdout.print(" per check\n", .{});

    const fpp = @intToFloat(f64, random_matches) * 1.0 / @intToFloat(f64, trials);
    std.debug.print("fpp (estimated): {d:3.10}\n", .{fpp});
    std.debug.print("bits per entry: {d:3.1}\n", .{@intToFloat(f64, filter.sizeInBytes()) * 8.0 / @intToFloat(f64, size)});
}

fn usage() void {
    std.debug.warn(
        \\benchmark [options]
        \\
        \\Options:
        \\  --xor         int             benchmark xor filter with N fingerprint bit size
        \\  --fuse        int             benchmark fuse filter with N fingerprint bit size
        \\  --num-keys    [int=1000000]   number of keys to insert
        \\  --num-trials  [int=10000000]  number of trials / containment checks to perform
        \\  --help
        \\
    , .{});
}
pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(buffer[0..]);
    const args = try std.process.argsAlloc(&fixed.allocator);

    var num_keys: usize = 1000000;
    var num_trials: usize = 10000000;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--num-keys")) {
            i += 1;
            if (i == args.len) {
                usage();
                std.os.exit(1);
            }
            num_keys = try std.fmt.parseUnsigned(usize, args[i], 10);
        }
        if (std.mem.eql(u8, args[i], "--num-trials")) {
            i += 1;
            if (i == args.len) {
                usage();
                std.os.exit(1);
            }
            num_trials = try std.fmt.parseUnsigned(usize, args[i], 10);
        }
    }

    i = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--xor")) {
            i += 1;
            if (i == args.len) {
                usage();
                std.os.exit(1);
            }
            const bit_size = try std.fmt.parseUnsigned(usize, args[i], 10);
            try stdout.print("benchmarking xor{}\n", .{bit_size});
            return switch (bit_size) {
                2 => return xorBench(u2, num_keys, num_trials),
                4 => return xorBench(u4, num_keys, num_trials),
                6 => return xorBench(u6, num_keys, num_trials),
                8 => return xorBench(u8, num_keys, num_trials),
                10 => return xorBench(u10, num_keys, num_trials),
                12 => return xorBench(u12, num_keys, num_trials),
                14 => return xorBench(u14, num_keys, num_trials),
                16 => return xorBench(u16, num_keys, num_trials),
                18 => return xorBench(u18, num_keys, num_trials),
                20 => return xorBench(u20, num_keys, num_trials),
                22 => return xorBench(u22, num_keys, num_trials),
                24 => return xorBench(u24, num_keys, num_trials),
                26 => return xorBench(u26, num_keys, num_trials),
                28 => return xorBench(u28, num_keys, num_trials),
                30 => return xorBench(u30, num_keys, num_trials),
                32 => return xorBench(u32, num_keys, num_trials),
                else => unreachable,
            };
        } else if (std.mem.eql(u8, args[i], "--fuse")) {
            i += 1;
            if (i == args.len) {
                usage();
                std.os.exit(1);
            }
            const bit_size = try std.fmt.parseUnsigned(usize, args[i], 10);
            try stdout.print("benchmarking fuse{}\n", .{bit_size});
            return switch (bit_size) {
                2 => return xorBench(u2, num_keys, num_trials),
                4 => return xorBench(u4, num_keys, num_trials),
                6 => return xorBench(u6, num_keys, num_trials),
                8 => return xorBench(u8, num_keys, num_trials),
                10 => return xorBench(u10, num_keys, num_trials),
                12 => return xorBench(u12, num_keys, num_trials),
                14 => return xorBench(u14, num_keys, num_trials),
                16 => return xorBench(u16, num_keys, num_trials),
                18 => return xorBench(u18, num_keys, num_trials),
                20 => return xorBench(u20, num_keys, num_trials),
                22 => return xorBench(u22, num_keys, num_trials),
                24 => return xorBench(u24, num_keys, num_trials),
                26 => return xorBench(u26, num_keys, num_trials),
                28 => return xorBench(u28, num_keys, num_trials),
                30 => return xorBench(u30, num_keys, num_trials),
                32 => return xorBench(u32, num_keys, num_trials),
                else => unreachable,
            };
        } else {
            usage();
            std.os.exit(1);
        }
    }
    usage();
    std.os.exit(1);
}
