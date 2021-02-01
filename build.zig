const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("xorfilter", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    var fusefilter_tests = b.addTest("src/fusefilter.zig");
    fusefilter_tests.setBuildMode(mode);

    var xorfilter_tests = b.addTest("src/xorfilter.zig");
    xorfilter_tests.setBuildMode(mode);

    var util_tests = b.addTest("src/util.zig");
    util_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&fusefilter_tests.step);
    test_step.dependOn(&xorfilter_tests.step);
    test_step.dependOn(&util_tests.step);
}
