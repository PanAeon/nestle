const Mapper = @import("Mapper.zig");
const NametableArragnment = Mapper.NametableArragnment;
const std = @import("std");
const Camerica = @This();
const expect = std.testing.expect;
prgROM: []u8,
chrROM: []u8,
chrRAM: []u8,
bankSelect: u4 = 0,
vram: []u8,
mirroring: NametableArragnment,



pub fn create(gpa: std.mem.Allocator, prgROM: []u8, chrROM: []u8, chrRAM: []u8, vram: []u8, mirroring: NametableArragnment) !*Camerica {
    var uxRom = try gpa.create(Mapper.Camerica);
    uxRom.prgROM = prgROM;
    uxRom.chrROM = chrROM;
    uxRom.chrRAM = chrRAM;
    uxRom.vram = vram;
    uxRom.mirroring = mirroring;
    uxRom.bankSelect = 0;
    return uxRom;
}

pub fn destroy(ptr: *anyopaque, gpa: std.mem.Allocator) void {
    const m: *Camerica = @ptrCast(@alignCast(ptr));
    gpa.free(m.prgROM);
    gpa.free(m.chrROM);
    gpa.free(m.chrRAM);
    gpa.destroy(m);
}

pub fn interface(self: *Camerica) Mapper {
    return .{
        .ptr = self,
        .vtable = &.{ .read = read, .write = write, .ppu_read = ppu_read, .ppu_write = ppu_write, .destroy = destroy,
            .serialize = serialize,
            .deserialize = deserialize,
            .byteSize = byteSize,
            .onScanline = onScanline
        },
    };
}

pub fn read(ptr: *anyopaque, addr: u16) u8 {
    const m: *Camerica = @ptrCast(@alignCast(ptr));

    switch (addr) {
        // usually cartridge ram when present
        0x6000...0x7FFF => return 0,
        0x8000...0xBFFF => {
            var foo:u4 = @truncate(m.bankSelect); // ok, dizzy needs 4, but adventures needs 3...
            if (foo >= m.prgROM.len / 0x4000) {
                foo = foo >> 1;
            }
            return m.prgROM[@as(u32, foo) * 0x4000 + @as(u32, addr) - 0x8000];
        },
        0xC000...0xFFFF => {
            const numBanks = m.prgROM.len / 0x4000;
            return m.prgROM[(numBanks - 1) * 0x4000 + @as(u32, addr) - 0xC000];
            // mapped to the last bank permanently
        },
        else => std.debug.panic("wrong address for mapper: {x}", .{addr}),
    }
}

pub fn write(ptr: *anyopaque, addr: u16, data: u8) void {
    const m: *Camerica = @ptrCast(@alignCast(ptr));
    // const m: *Camerica = @alignCast(@fieldParentPtr("interface", self));
    // return self.writeFn(self.ptr, addr, data);
    switch (addr) {
        // usually cartridge ram when present
        0x6000...0xBFFF => {
        },
        0xC000...0xFFFF => {
            m.bankSelect = @truncate(data); //@as(u3, @truncate(data));
        },
        else => {
            // m.currentBank = data & 0b00000111; // at least mgs does this..
        }, // std.debug.panic("wrong address for mapper: 0x{x}", .{addr}),
    }
}

pub fn ppu_read(ptr: *anyopaque, addr: u14) u8 {
    const m: *Camerica = @ptrCast(@alignCast(ptr));
    switch (m.mirroring) {
        .Horizontal => switch (addr) {
            0x0000...0x1FFF => return if (m.chrROM.len == 0) m.chrRAM[addr] else m.chrROM[addr], // 8kb of chrRAM
            //// 2kb of internal ram, but 4kb of name pages
            0x2000...0x23FF => return m.vram[addr - 0x2000],
            0x2400...0x27FF => return m.vram[addr - 0x2000],
            0x2800...0x2BFF => return m.vram[addr - 0x2800],
            0x2C00...0x2FFF => return m.vram[addr - 0x2800],
            else => @panic("boo"),
        },
        .Vertical => switch (addr) {
            0x0000...0x1FFF => return if (m.chrROM.len == 0) m.chrRAM[addr] else m.chrROM[addr], // 8kb of chrRAM
            //// 2kb of internal ram, but 4kb of name pages
            0x2000...0x23FF => return m.vram[addr - 0x2000],
            0x2400...0x27FF => return m.vram[addr - 0x2400],
            0x2800...0x2BFF => return m.vram[addr - 0x2400],
            0x2C00...0x2FFF => return m.vram[addr - 0x2800],
            else => @panic("boo"),
        },
        else => std.debug.panic("unsupported mirroring by Camerica {any}", .{m.mirroring}),
    }
}

pub fn ppu_write(ptr: *anyopaque, addr: u14, data: u8) void {
    const m: *Camerica = @ptrCast(@alignCast(ptr));
    switch (m.mirroring) {
        .Horizontal => switch (addr) {
            0x0000...0x1FFF => m.chrRAM[addr] = data, // 8kb of chrRAM
            //// 2kb of internal ram, but 4kb of name pages
            0x2000...0x23FF => m.vram[addr - 0x2000] = data,
            0x2400...0x27FF => m.vram[addr - 0x2000] = data,
            0x2800...0x2BFF => m.vram[addr - 0x2800] = data,
            0x2C00...0x2FFF => m.vram[addr - 0x2800] = data,
            else => std.debug.panic("(write) wrong vram address: 0x{x}", .{addr}),
        },
        .Vertical => switch (addr) {
            0x0000...0x1FFF => m.chrRAM[addr] = data, // 8kb of chrRAM
            //// 2kb of internal ram, but 4kb of name pages
            0x2000...0x23FF => m.vram[addr - 0x2000] = data,
            0x2400...0x27FF => m.vram[addr - 0x2400] = data,
            0x2800...0x2BFF => m.vram[addr - 0x2400] = data,
            0x2C00...0x2FFF => m.vram[addr - 0x2800] = data,
            else => std.debug.panic("(write) wrong vram address: 0x{x}", .{addr}),
        },
        else => std.debug.panic("unsupported mirroring by Camerica {any}", .{m.mirroring}),
    }
}


pub fn serialize(ptr: *anyopaque, writer: *std.Io.Writer) !void {
    const m: *Camerica = @ptrCast(@alignCast(ptr));
    try writer.writeByte(m.bankSelect);
    try writer.writeAll(m.chrRAM);
    
}
pub fn deserialize(ptr: *anyopaque, reader: *std.Io.Reader) !void {
    const m: *Camerica = @ptrCast(@alignCast(ptr));
    m.bankSelect = @truncate(try reader.takeByte());
    var writer = std.Io.Writer.fixed(m.chrRAM);
    try reader.streamExact(&writer, m.chrRAM.len);
}
pub fn byteSize(ptr: *anyopaque) u64 {
    const m: *Camerica = @ptrCast(@alignCast(ptr));
    return 1 + m.chrRAM.len;
}

pub fn onScanline(_: *anyopaque) bool {
    return false;
}
