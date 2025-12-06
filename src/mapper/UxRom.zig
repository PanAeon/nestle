const Mapper = @import("Mapper.zig");
const Mirroring = Mapper.Mirroring;
const std = @import("std");
const UxRom = @This();
const expect = std.testing.expect;
prgROM: []u8,
chrROM: []u8,
chrRAM: []u8,
currentBank: u16 = 0,
vram: []u8,
mirroring: Mirroring,
// chrRAM: 8kb?, mirror: vertical

pub fn init(gpa: std.mem.Allocator, prgROM: []u8, chrROM: []u8, chrRAM: []u8, vram: []u8, mirroring: Mirroring) !*UxRom {
            var uxRom = try gpa.create(Mapper.UxRom);
            uxRom.prgROM = prgROM;
            uxRom.chrROM = chrROM;
            uxRom.chrRAM = chrRAM;
            uxRom.vram = vram;
            uxRom.mirroring = mirroring;
    return uxRom;
}

pub fn deinit(ptr: *anyopaque, gpa: std.mem.Allocator) void {
    const m: *UxRom = @ptrCast(@alignCast(ptr));
    gpa.free(m.prgROM);
    gpa.free(m.chrROM);
    gpa.free(m.chrRAM);
    gpa.destroy(m);
}

pub fn interface(self: *UxRom) Mapper {
    return .{
        .ptr = self,
        .vtable = &.{ .read = read, .write = write, .ppu_read = ppu_read, .ppu_write = ppu_write, .deinit = deinit },
    };
}

pub fn read(ptr: *anyopaque, addr: u16) u8 {
    const m: *UxRom = @ptrCast(@alignCast(ptr));

    // std.debug.print(">>> ??: {d}\n", .{m.i});

    // std.debug.print("rom len: {d}\n", .{self.prgROM.len});
    // return self.readFn(self.ptr, addr);
    // const firstBankData = m.prgROM[0..0x4000];
    // _ = &firstBankData;
    // mapped into $8000-$BFFF
    //
    // const lastBankData = m.prgROM[7 * 0x4000 .. 8 * 0x4000]; //16kb we need;
    switch (addr) {
        // usually cartridge ram when present
        0x6000...0x7FFF => return 0,
        0x8000...0xBFFF => {
            // mapped to the first bank currently
            // std.debug.print("current bank: {d}\n", .{m.currentBank});
            return m.prgROM[@as(u32, m.currentBank) * 0x4000 + @as(u32, addr) - 0x8000];
        },
        0xC000...0xFFFF => {
            return m.prgROM[7 * 0x4000 + @as(u32, addr) - 0xC000];
            // mapped to the last bank permanently
        },
        else => std.debug.panic("wrong address for mapper: {x}", .{addr}),
    }

    // const low:u16 = lastBankData[0x3FFC];
    // const high:u16 = lastBankData[0x3FFD];
    // std.debug.print("> low 0x{x} high 0x{x}\n", .{low, high});

    // const jmp = low + (high*256);
    // std.debug.print("> address {d}, 0x{x}\n", .{jmp, jmp});
    // std.debug.print("> data {x}\n" ,
    // .{prgROM[0x1c196..16 + 0x1c196]});
    // std.debug.print("> data {x}\n" ,
    // .{prgROM[@as(u32, 0x10000) + jmp..@as(u43, 0x10000) + jmp + 16]});
    // std.debug.print("> data {x}\n", .{lastBankData[jmp-0xC000..jmp-0xC000+16]});
    // std.fmt.hexToBytes(u, input: []const u8)
    // return 0;
}

pub fn write(ptr: *anyopaque, addr: u16, data: u8) void {
    const m: *UxRom = @ptrCast(@alignCast(ptr));
    // const m: *UxRom = @alignCast(@fieldParentPtr("interface", self));
    // return self.writeFn(self.ptr, addr, data);
    switch (addr) {
        // usually cartridge ram when present
        0x6000...0x7FFF => {
            std.debug.print(">UxRom write on 0x{x}, value: 0x{x}", .{ addr, data });
            // m.currentBank = data & 0b0000111; //@as(u3, @truncate(data));
        },
        0x8000...0xFFFF => {
            // switch rom
            // 7  bit  0
            // ---- ----
            // xxxx pPPP
            //      ||||
            //      ++++- Select 16 KB PRG ROM bank for CPU $8000-$BFFF
            //           (UNROM uses bits 2-0; UOROM uses bits 3-0)
            //           will use bits 2-0 for now..
            // m.prgROM[m.currentBank * 0x4000 + @as(u32, addr) - 0x8000] = data;
            m.currentBank = data & 0b0000111; //@as(u3, @truncate(data));
        },
        else => std.debug.panic("wrong address for mapper: {x}", .{addr}),
    }
}

// 0x2000 | 0x2400  ||
// 0x2800 | 0x2C00  ||
// should map to 0x0000-0x2400, as we have 2kb of intenal rom
// FIXME: proper unit test for vertical arrangment
pub fn ppu_read(ptr: *anyopaque, addr: u14) u8 {
    const m: *UxRom = @ptrCast(@alignCast(ptr));
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
        else => std.debug.panic("unsupported mirroring by UxRom {any}", .{m.mirroring}),
    }
}

pub fn ppu_write(ptr: *anyopaque, addr: u14, data: u8) void {
    const m: *UxRom = @ptrCast(@alignCast(ptr));
    switch (m.mirroring) {
        .Horizontal => switch (addr) {
            0x0000...0x1FFF => m.chrRAM[addr] = data, // 8kb of chrRAM
            //// 2kb of internal ram, but 4kb of name pages
            0x2000...0x23FF => m.vram[addr - 0x2000] = data,
            0x2400...0x27FF => m.vram[addr - 0x2000] = data,
            0x2800...0x2BFF => m.vram[addr - 0x2800] = data,
            0x2C00...0x2FFF => m.vram[addr - 0x2800] = data,
            else => @panic("boo"),
        },
        .Vertical => switch (addr) {
            0x0000...0x1FFF => m.chrRAM[addr] = data, // 8kb of chrRAM
            //// 2kb of internal ram, but 4kb of name pages
            0x2000...0x23FF => m.vram[addr - 0x2000] = data,
            0x2400...0x27FF => m.vram[addr - 0x2400] = data,
            0x2800...0x2BFF => m.vram[addr - 0x2400] = data,
            0x2C00...0x2FFF => m.vram[addr - 0x2800] = data,
            else => @panic("boo"),
        },
        else => std.debug.panic("unsupported mirroring by UxRom {any}", .{m.mirroring}),
    }
}

test "Horizontal must mirror horizontally" {
    var rom = [_]u8{};
    var chrRAM = [_]u8{};
    var uxrom = UxRom.init(&rom, &chrRAM, .Horizontal);
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
    var uxrom = UxRom.init(&rom, &chrRAM, .Vertical);
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
