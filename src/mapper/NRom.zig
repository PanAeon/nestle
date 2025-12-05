const Mapper = @import("Mapper.zig");
const Mirroring = Mapper.Mirroring;
const std = @import("std");
const NRom = @This();
const expect = std.testing.expect;
prgROM: []u8,
chrROM: []u8,
chrRAM: []u8,
internalRAM: []u8,
mirroring: Mirroring,
prgRAM:[2048]u8, // or 4k in Family Basic only

pub fn init(rom: []u8, chrROM: []u8, chrRAM: []u8, vram: []u8, mirroring:Mirroring) NRom {
    return .{ 
        .prgROM = rom, 
        .prgRAM = .{0}**2048,
        .chrRAM = chrRAM, 
        .chrROM = chrROM,
        .mirroring = mirroring,
        .internalRAM = vram};
}

pub fn interface(self: *NRom) Mapper {
    return .{
        .ptr = self,
        .vtable = &.{
            .read = read,
            .write = write,
            .ppu_read = ppu_read,
            .ppu_write = ppu_write,
        },
    };
}

//     CPU $6000-$7FFF: Unbanked PRG-RAM, mirrored as necessary to fill entire 8 KiB window,
//     write protectable with an external switch. (Family BASIC only)
//     CPU $8000-$BFFF: First 16 KiB of PRG-ROM.
//     CPU $C000-$FFFF: Last 16 KiB of PRG-ROM (NROM-256) or mirror of $8000-$BFFF (NROM-128).
//     PPU $0000-$1FFF: 8 KiB CHR-ROM.
//
// All banks are fixed.
pub fn read(ptr: *anyopaque, addr: u16) u8 {
    const m: *NRom = @ptrCast(@alignCast(ptr));

    switch (addr) {
        // usually cartridge ram when present
        0x6000...0x7FFF => return m.prgRAM[addr - 0x6000], //FIXME: mirror
        0x8000...0xBFFF => {
            return m.prgROM[addr - 0x8000];
        },
        0xC000...0xFFFF => {
            return m.prgROM[addr - 0xC000]; // FIXME: nrom-256?
        },
        else => std.debug.panic("wrong address for mapper: {x}", .{addr}),
    }

}

pub fn write(ptr: *anyopaque, addr: u16, data: u8) void {
    const m: *NRom = @ptrCast(@alignCast(ptr));
    switch (addr) {
        0x6000...0x7FFF => { 
            m.prgRAM[addr - 0x6000] = data;
        },
        0x8000...0xBFFF => {
            m.prgROM[addr - 0x8000] = data;
        },
        0xC000...0xFFFF => {
            m.prgROM[addr - 0xC000] = data; // FIXME: nrom-256?
        },
        else => std.debug.panic("wrong address for mapper: {x}", .{addr}),
    }
}

// 0x2000 | 0x2400  ||
// 0x2800 | 0x2C00  ||
// should map to 0x0000-0x2400, as we have 2kb of intenal rom
// FIXME: proper unit test for vertical arrangment
pub fn ppu_read(ptr: *anyopaque, addr: u14) u8 {
    const m: *NRom = @ptrCast(@alignCast(ptr));
    switch (m.mirroring) {
    .Horizontal => switch (addr) {
        0x0000...0x1FFF =>  return m.chrROM[addr],
        //// 2kb of internal ram, but 4kb of name pages
        0x2000...0x23FF => return m.internalRAM[addr - 0x2000],
        0x2400...0x27FF => return m.internalRAM[addr - 0x2000],
        0x2800...0x2BFF => return m.internalRAM[addr - 0x2800],
        0x2C00...0x2FFF => return m.internalRAM[addr - 0x2800],
        else =>  @panic("boo"),
    },
    .Vertical => switch (addr) {
        0x0000...0x1FFF => {return m.chrROM[addr];}, 
        //// 2kb of internal ram, but 4kb of name pages
        0x2000...0x23FF => return m.internalRAM[addr - 0x2000],
        0x2400...0x27FF => return m.internalRAM[addr - 0x2400],
        0x2800...0x2BFF => return m.internalRAM[addr - 0x2400],
        0x2C00...0x2FFF => return m.internalRAM[addr - 0x2800],
        else =>  @panic("boo"),
    },
    else => std.debug.panic("unsupported mirroring by UxRom {any}", .{m.mirroring})
    }
}

pub fn ppu_write(ptr: *anyopaque, addr: u14, data: u8) void {
    const m: *NRom = @ptrCast(@alignCast(ptr));
    switch (m.mirroring) {
    .Horizontal => switch (addr) {
        0x0000...0x1FFF => {}, // 8kb of chrRAM
        //// 2kb of internal ram, but 4kb of name pages
        0x2000...0x23FF => m.internalRAM[addr - 0x2000] = data,
        0x2400...0x27FF => m.internalRAM[addr - 0x2000] = data,
        0x2800...0x2BFF => m.internalRAM[addr - 0x2800] = data,
        0x2C00...0x2FFF => m.internalRAM[addr - 0x2800] = data,
        else =>  @panic("boo"),
    },
    .Vertical => switch (addr) {
        0x0000...0x1FFF => {}, // 8kb of chrRAM
        //// 2kb of internal ram, but 4kb of name pages
        0x2000...0x23FF => m.internalRAM[addr - 0x2000] = data,
        0x2400...0x27FF => m.internalRAM[addr - 0x2400] = data,
        0x2800...0x2BFF => m.internalRAM[addr - 0x2400] = data,
        0x2C00...0x2FFF => m.internalRAM[addr - 0x2800] = data,
        else =>  @panic("boo"),
    },
    else => std.debug.panic("unsupported mirroring by UxRom {any}", .{m.mirroring})
    }
}

test "Horizontal must mirror horizontally" {
    var rom = [_]u8{};
    var chrRAM = [_]u8{};
    var uxrom = NRom.init(&rom, &chrRAM, .Horizontal);
    var mapper = uxrom.interface();
    mapper.ppu_write(0x20F0, 13);
    try expect(mapper.ppu_read(0x28F0) == 13);
    mapper.ppu_write(0x24F0, 7);
    try expect(mapper.ppu_read(0x2CF0) == 7);
    mapper.ppu_write(0x2CF0, 7);
    try expect(mapper.ppu_read(0x20F0) == 13);
    mapper.ppu_write(0x28F0, 7);
    try expect(mapper.ppu_read(0x20F0) == 7);

}
//  $2000 and $2400 contain the first nametable,
//  and $2800 and $2C00 contain the second nametable
test "Vertical must mirror vertically" {
    var rom = [_]u8{};
    var chrRAM = [_]u8{};
    var uxrom = NRom.init(&rom, &chrRAM, .Vertical);
    var mapper = uxrom.interface();
    mapper.ppu_write(0x20F0, 13);
    try expect(mapper.ppu_read(0x24F0) == 13);
    mapper.ppu_write(0x28F0, 7);
    try expect(mapper.ppu_read(0x2CF0) == 7);
    mapper.ppu_write(0x2CF0, 7);
    try expect(mapper.ppu_read(0x28F0) == 7);
    mapper.ppu_write(0x28F0, 9);
    try expect(mapper.ppu_read(0x2CF0) == 9);

}
