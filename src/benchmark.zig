// zig run -O ReleaseFast src/benchmark.zig

const std = @import("std");
const time = std.time;
const Timer = time.Timer;
const xorfilter = @import("main.zig");
const MeasuredAllocator = @import("MeasuredAllocator.zig");

fn formatTime(writer: anytype, comptime spec: []const u8, start: u64, end: u64, division: usize) !void {
    const ns = @as(f64, @floatFromInt((end - start) / division));
    if (ns <= time.ns_per_ms) {
        try writer.print(spec, .{ ns, "ns " });
        return;
    }
    if (ns <= time.ns_per_s) {
        try writer.print(spec, .{ ns / @as(f64, @floatFromInt(time.ns_per_ms)), "ms " });
        return;
    }
    if (ns <= time.ns_per_min) {
        try writer.print(spec, .{ ns / @as(f64, @floatFromInt(time.ns_per_s)), "s  " });
        return;
    }
    try writer.print(spec, .{ ns / @as(f64, @floatFromInt(time.ns_per_min)), "min" });
    return;
}

fn formatBytes(writer: anytype, comptime spec: []const u8, bytes: u64) !void {
    const kib = 1024;
    const mib = 1024 * kib;
    const gib = 1024 * mib;
    if (bytes < kib) {
        try writer.print(spec, .{ bytes, "B  " });
    }
    if (bytes < mib) {
        try writer.print(spec, .{ bytes / kib, "KiB" });
        return;
    }
    if (bytes < gib) {
        try writer.print(spec, .{ bytes / mib, "MiB" });
        return;
    }
    try writer.print(spec, .{ bytes / gib, "GiB" });
    return;
}

fn bench(algorithm: []const u8, Filter: anytype, size: usize, trials: usize) !void {
    const allocator = std.heap.page_allocator;

    var filterMA = MeasuredAllocator.init(allocator);
    const filterAllocator = filterMA.allocator();

    var buildMA = MeasuredAllocator.init(allocator);
    const buildAllocator = buildMA.allocator();

    var timer = try Timer.start();

    // Initialize filter.
    var filter = try Filter.init(filterAllocator, size);
    defer filter.deinit(allocator);

    // Generate keys.
    var keys = try allocator.alloc(u64, size);
    defer allocator.free(keys);
    for (keys, 0..) |_, i| {
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
    var rng = std.Random.DefaultPrng.init(0);
    const random = rng.random();
    timer.reset();
    const randomMatchesTimeStart = timer.lap();
    while (i < trials) : (i += 1) {
        const random_key: u64 = random.uintAtMost(u64, std.math.maxInt(u64));
        if (filter.contain(random_key)) {
            if (random_key >= keys.len) {
                random_matches += 1;
            }
        }
    }
    const randomMatchesTimeEnd = timer.read();

    const fpp = @as(f64, @floatFromInt(random_matches)) * 1.0 / @as(f64, @floatFromInt(trials));

    const bitsPerEntry = @as(f64, @floatFromInt(filter.sizeInBytes())) * 8.0 / @as(f64, @floatFromInt(size));
    const filterBitsPerEntry = @as(f64, @floatFromInt(filterMA.state.peak_memory_usage_bytes)) * 8.0 / @as(f64, @floatFromInt(size));
    if (!std.math.approxEqAbs(f64, filterBitsPerEntry, bitsPerEntry, 0.001)) {
        @panic("sizeInBytes reporting wrong numbers?");
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("| {s: <12} ", .{algorithm});
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
    std.log.warn(
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
    const args = try std.process.argsAlloc(fixed.allocator());

    var num_trials: usize = 100_000_000;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--num-trials")) {
            i += 1;
            if (i == args.len) {
                usage();
                std.process.exit(1);
            }
            num_trials = try std.fmt.parseUnsigned(usize, args[i], 10);
        }
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("| Algorithm    | # of keys  | populate   | contains(k) | false+ prob. | bits per entry | peak populate | filter total |\n", .{});
    try stdout.print("|--------------|------------|------------|-------------|--------------|----------------|---------------|--------------|\n", .{});
    try bench("binaryfuse8", xorfilter.BinaryFuse(u8), 1_000_000, num_trials);
    try bench("binaryfuse16", xorfilter.BinaryFuse(u16), 1_000_000, num_trials);
    try bench("binaryfuse32", xorfilter.BinaryFuse(u32), 1_000_000, num_trials);
    try bench("xor2", xorfilter.Xor(u2), 1_000_000, num_trials);
    try bench("xor4", xorfilter.Xor(u4), 1_000_000, num_trials);
    try bench("xor8", xorfilter.Xor(u8), 1_000_000, num_trials);
    try bench("xor16", xorfilter.Xor(u16), 1_000_000, num_trials);
    try bench("xor32", xorfilter.Xor(u32), 1_000_000, num_trials);
    try stdout.print("|              |            |            |             |              |                |               |              |\n", .{});
    try bench("binaryfuse8", xorfilter.BinaryFuse(u8), 10_000_000, num_trials / 10);
    try bench("binaryfuse16", xorfilter.BinaryFuse(u16), 10_000_000, num_trials / 10);
    try bench("binaryfuse32", xorfilter.BinaryFuse(u32), 10_000_000, num_trials / 10);
    try bench("xor2", xorfilter.Xor(u2), 10_000_000, num_trials / 10);
    try bench("xor4", xorfilter.Xor(u4), 10_000_000, num_trials / 10);
    try bench("xor8", xorfilter.Xor(u8), 10_000_000, num_trials / 10);
    try bench("xor16", xorfilter.Xor(u16), 10_000_000, num_trials / 10);
    try bench("xor32", xorfilter.Xor(u32), 10_000_000, num_trials / 10);
    try stdout.print("|              |            |            |             |              |                |               |              |\n", .{});
    try bench("binaryfuse8", xorfilter.BinaryFuse(u8), 100_000_000, num_trials / 100);
    try bench("binaryfuse16", xorfilter.BinaryFuse(u16), 100_000_000, num_trials / 100);
    try bench("binaryfuse32", xorfilter.BinaryFuse(u32), 100_000_000, num_trials / 100);
    try bench("xor2", xorfilter.Xor(u2), 100_000_000, num_trials / 100);
    try bench("xor4", xorfilter.Xor(u4), 100_000_000, num_trials / 100);
    try bench("xor8", xorfilter.Xor(u8), 100_000_000, num_trials / 100);
    try bench("xor16", xorfilter.Xor(u16), 100_000_000, num_trials / 100);
    try bench("xor32", xorfilter.Xor(u32), 100_000_000, num_trials / 100);
    try stdout.print("|              |            |            |             |              |                |               |              |\n", .{});
    try stdout.print("\n", .{});
    try stdout.print("Legend:\n\n", .{});
    try stdout.print("* **contains(k)**: The time taken to check if a key is in the filter\n", .{});
    try stdout.print("* **false+ prob.**: False positive probability, the probability that a containment check will erroneously return true for a key that has not actually been added to the filter.\n", .{});
    try stdout.print("* **bits per entry**: The amount of memory in bits the filter uses to store a single entry.\n", .{});
    try stdout.print("* **peak populate**: Amount of memory consumed during filter population, excluding keys themselves (8 bytes * num_keys.)\n", .{});
    try stdout.print("* **filter total**: Amount of memory consumed for filter itself in total (bits per entry * entries.)\n", .{});
}
