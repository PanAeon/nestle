const std = @import("std");
const Allocator = std.mem.Allocator;

pub const NRom = @import("NRom.zig");
pub const UxRom = @import("UxRom.zig");
pub const MMC1 = @import("MMC1.zig");

pub const Mirroring = enum { Horizontal, Vertical, SingleScreen, FourScreens, Other };
const Mapper = @This();
ptr: *anyopaque,
vtable: *const VTable,
pub const VTable = struct { read: *const fn (ptr: *anyopaque, addr: u16) u8, write: *const fn (ptr: *anyopaque, addr: u16, data: u8) void, ppu_read: *const fn (ptr: *anyopaque, addr: u14) u8, ppu_write: *const fn (ptr: *anyopaque, addr: u14, data: u8) void, destroy: *const fn (
    ptr: *anyopaque,
    gpa: Allocator,
) void };

pub inline fn read(self: *Mapper, addr: u16) u8 {
    return self.vtable.read(self.ptr, addr);
}

pub inline fn write(self: *Mapper, addr: u16, data: u8) void {
    return self.vtable.write(self.ptr, addr, data);
}

pub inline fn ppu_read(self: *Mapper, addr: u14) u8 {
    return self.vtable.ppu_read(self.ptr, addr);
}

pub inline fn ppu_write(self: *Mapper, addr: u14, data: u8) void {
    return self.vtable.ppu_write(self.ptr, addr, data);
}

pub fn destroy(self: *Mapper, gpa: Allocator) void {
    self.vtable.destroy(self.ptr, gpa);
}
