// zig run -O ReleaseFast src/benchmark.zig

const std = @import("std");
const time = std.time;
const Timer = time.Timer;
const xorfilter = @import("main.zig");
const MeasuredAllocator = @import("MeasuredAllocator.zig");

fn formatTime(writer: anytype, comptime spec: []const u8, start: u64, end: u64, division: usize) !void {
    const ns = @intToFloat(f64, (end - start) / division);
    if (ns <= time.ns_per_ms) {
        try std.fmt.format(writer, spec, .{ ns, "ns " });
        return;
    }
    if (ns <= time.ns_per_s) {
        try std.fmt.format(writer, spec, .{ ns / @intToFloat(f64, time.ns_per_ms), "ms " });
        return;
    }
    if (ns <= time.ns_per_min) {
        try std.fmt.format(writer, spec, .{ ns / @intToFloat(f64, time.ns_per_s), "s  " });
        return;
    }
    try std.fmt.format(writer, spec, .{ ns / @intToFloat(f64, time.ns_per_min), "min" });
    return;
}

fn formatBytes(writer: anytype, comptime spec: []const u8, bytes: u64) !void {
    const kib = 1024;
    const mib = 1024 * kib;
    const gib = 1024 * mib;
    if (bytes < kib) {
        try std.fmt.format(writer, spec, .{ bytes, "B  " });
    }
    if (bytes < mib) {
        try std.fmt.format(writer, spec, .{ bytes / kib, "KiB" });
        return;
    }
    if (bytes < gib) {
        try std.fmt.format(writer, spec, .{ bytes / mib, "MiB" });
        return;
    }
    try std.fmt.format(writer, spec, .{ bytes / gib, "GiB" });
    return;
}

fn bench(algorithm: []const u8, Filter: anytype, size: usize, trials: usize) !void {
    const allocator = std.heap.page_allocator;

    var filterMA = MeasuredAllocator.init(allocator);
    var filterAllocator = &filterMA.allocator;

    var buildMA = MeasuredAllocator.init(allocator);
    var buildAllocator = &buildMA.allocator;

    const stdout = std.io.getStdOut().writer();
    var timer = try Timer.start();

    // Initialize filter.
    const filter = try Filter.init(filterAllocator, size);
    defer filter.deinit();

    // Generate keys.
    var keys = try allocator.alloc(u64, size);
    defer allocator.free(keys);
    for (keys) |_, i| {
        keys[i] = i;
    }

    // Populate filter.
    timer.reset();
    const populateTimeStart = timer.lap();
    try filter.populate(buildAllocator, keys[0..]);
    const populateTimeEnd = timer.read();

    // Perform random matches.
    var random_matches: u64 = 0;
    var i: u64 = 0;
    var default_prng = std.rand.DefaultPrng.init(0);
    timer.reset();
    const randomMatchesTimeStart = timer.lap();
    while (i < trials) : (i += 1) {
        var random_key: u64 = default_prng.random.uintAtMost(u64, std.math.maxInt(u64));
        if (filter.contain(random_key)) {
            if (random_key >= keys.len) {
                random_matches += 1;
            }
        }
    }
    const randomMatchesTimeEnd = timer.read();

    const fpp = @intToFloat(f64, random_matches) * 1.0 / @intToFloat(f64, trials);

    const bitsPerEntry = @intToFloat(f64, filter.sizeInBytes()) * 8.0 / @intToFloat(f64, size);
    const filterBitsPerEntry = @intToFloat(f64, filterMA.state.peak_memory_usage_bytes) * 8.0 / @intToFloat(f64, size);
    if (!std.math.approxEqAbs(f64, filterBitsPerEntry, bitsPerEntry, 0.001)) {
        @panic("sizeInBytes reporting wrong numbers?");
    }

    try stdout.print("| {s: <10} ", .{algorithm});
    try stdout.print("| {: <10} ", .{keys.len});
    try stdout.print("| ", .{});
    try formatTime(stdout, "{d: >7.1}{s}", populateTimeStart, populateTimeEnd, 1);
    try stdout.print(" | ", .{});
    try formatTime(stdout, "{d: >8.1}{s}", randomMatchesTimeStart, randomMatchesTimeEnd, trials);
    try stdout.print(" | {d: >12} ", .{fpp});
    try stdout.print("| {d: >14.2} ", .{bitsPerEntry});
    try stdout.print("| ", .{});
    try formatBytes(stdout, "{: >9} {s}", buildMA.state.peak_memory_usage_bytes);
    try formatBytes(stdout, " | {: >8} {s}", filterMA.state.peak_memory_usage_bytes);
    try stdout.print(" |\n", .{});
}

fn usage() void {
    std.debug.warn(
        \\benchmark [options]
        \\
        \\Options:
        \\  --num-trials  [int=10000000]  number of trials / containment checks to perform
        \\  --help
        \\
    , .{});
}
pub fn main() !void {
    var buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(buffer[0..]);
    const args = try std.process.argsAlloc(&fixed.allocator);

    var num_trials: usize = 100_000_000;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--num-trials")) {
            i += 1;
            if (i == args.len) {
                usage();
                std.os.exit(1);
            }
            num_trials = try std.fmt.parseUnsigned(usize, args[i], 10);
        }
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("| Algorithm  | # of keys  | populate   | contains(k) | false+ prob. | bits per entry | peak populate | filter total |\n", .{});
    try stdout.print("|------------|------------|------------|-------------|--------------|----------------|---------------|--------------|\n", .{});
    try bench("xor2", xorfilter.Xor(u2), 1_000_000, num_trials);
    try bench("xor4", xorfilter.Xor(u4), 1_000_000, num_trials);
    try bench("xor8", xorfilter.Xor(u8), 1_000_000, num_trials);
    try bench("xor16", xorfilter.Xor(u16), 1_000_000, num_trials);
    try bench("xor32", xorfilter.Xor(u32), 1_000_000, num_trials);
    try bench("fuse8", xorfilter.Fuse(u8), 1_000_000, num_trials);
    try bench("fuse16", xorfilter.Fuse(u16), 1_000_000, num_trials);
    try bench("fuse32", xorfilter.Fuse(u32), 1_000_000, num_trials);
    try stdout.print("|            |            |            |             |              |                |               |              |\n", .{});
    try bench("xor2", xorfilter.Xor(u2), 10_000_000, num_trials / 10);
    try bench("xor4", xorfilter.Xor(u4), 10_000_000, num_trials / 10);
    try bench("xor8", xorfilter.Xor(u8), 10_000_000, num_trials / 10);
    try bench("xor16", xorfilter.Xor(u16), 10_000_000, num_trials / 10);
    try bench("xor32", xorfilter.Xor(u32), 10_000_000, num_trials / 10);
    try bench("fuse8", xorfilter.Fuse(u8), 10_000_000, num_trials / 10);
    try bench("fuse16", xorfilter.Fuse(u16), 10_000_000, num_trials / 10);
    try bench("fuse32", xorfilter.Fuse(u32), 10_000_000, num_trials / 10);
    try stdout.print("|            |            |            |             |              |                |               |              |\n", .{});
    try bench("xor2", xorfilter.Xor(u2), 100_000_000, num_trials / 100);
    try bench("xor4", xorfilter.Xor(u4), 100_000_000, num_trials / 100);
    try bench("xor8", xorfilter.Xor(u8), 100_000_000, num_trials / 100);
    try bench("xor16", xorfilter.Xor(u16), 100_000_000, num_trials / 100);
    try bench("xor32", xorfilter.Xor(u32), 100_000_000, num_trials / 100);
    try bench("fuse8", xorfilter.Fuse(u8), 100_000_000, num_trials / 100);
    try bench("fuse16", xorfilter.Fuse(u16), 100_000_000, num_trials / 100);
    try bench("fuse32", xorfilter.Fuse(u32), 100_000_000, num_trials / 100);
    try stdout.print("|            |            |            |             |              |                |               |              |\n", .{});
    try stdout.print("\n", .{});
    try stdout.print("Legend:\n\n", .{});
    try stdout.print("* **contains(k)**: The time taken to check if a key is in the filter\n", .{});
    try stdout.print("* **false+ prob.**: False positive probability, the probability that a containment check will erroneously return true for a key that has not actually been added to the filter.\n", .{});
    try stdout.print("* **bits per entry**: The amount of memory in bits the filter uses to store a single entry.\n", .{});
    try stdout.print("* **peak populate**: Amount of memory consumed during filter population, excluding keys themselves (8 bytes * num_keys.)\n", .{});
    try stdout.print("* **filter total**: Amount of memory consumed for filter itself in total (bits per entry * entries.)\n", .{});
}
