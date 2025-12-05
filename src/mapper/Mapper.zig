const std = @import("std");

pub const Mirroring = enum {
    Horizontal,
    Vertical,
    SingleScreen,
    FourScreens,
    Other
};
const Mapper = @This();
ptr: *anyopaque,
vtable: *const VTable,
pub const VTable = struct {
    read: *const fn (ptr: *anyopaque, addr: u16) u8,
    write: *const fn (ptr: *anyopaque, addr: u16, data: u8) void,
    ppu_read: *const fn (ptr: *anyopaque, addr: u14) u8,
    ppu_write: *const fn (ptr: *anyopaque, addr: u14, data: u8) void,
};

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
