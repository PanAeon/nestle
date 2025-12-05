const std = @import("std");
pub const ines = @import("loader/ines.zig");
pub const Emulator = @import("Emulator.zig");
pub const core = struct {
    pub const MemoryController = @import("core/MemoryController.zig");
    pub const Cpu = @import("core/Cpu.zig");
    pub const Apu = @import("core/Apu.zig");
    pub const Ppu = @import("core/Ppu.zig");
    pub const OpenBus = @import("core/OpenBus.zig");
    pub const Controller = @import("core/Controller.zig");
};
pub const mapper = struct {
    pub const Mapper = @import("mapper/Mapper.zig");
    pub const UxRom = @import("mapper/UxRom.zig");
    pub const NRom = @import("mapper/NRom.zig");
};

pub fn bufferedPrint() !void {
    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush(); // Don't forget to flush!
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
