const Mapper = @import("Mapper.zig");
const NametableArragnment = Mapper.NametableArragnment;
const std = @import("std");
const AxRom = @This();
const expect = std.testing.expect;
prgROM: []u8,
chrROM: []u8,
chrRAM: []u8,
vram: []u8,
bankSelect: BankSelect,

pub fn create(gpa: std.mem.Allocator, prgROM: []u8, chrROM: []u8, chrRAM: []u8, vram: []u8) !*AxRom {
    var axRom = try gpa.create(Mapper.AxRom);
    axRom.prgROM = prgROM;
    axRom.chrROM = chrROM;
    axRom.chrRAM = chrRAM;
    axRom.vram = vram;
    axRom.bankSelect = .{};
    return axRom;
}

pub fn destroy(ptr: *anyopaque, gpa: std.mem.Allocator) void {
    const m: *AxRom = @ptrCast(@alignCast(ptr));
    gpa.free(m.prgROM);
    gpa.free(m.chrROM);
    gpa.free(m.chrRAM);
    gpa.destroy(m);
}

pub fn interface(self: *AxRom) Mapper {
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
    const m: *AxRom = @ptrCast(@alignCast(ptr));

    switch (addr) {
        // usually cartridge ram when present
        0x6000...0x7FFF => return 0,
        0x8000...0xFFFF => {
            return m.prgROM[@as(u32, m.bankSelect.prgROMSelect) * 0x8000 + @as(u32, addr) - 0x8000];
        },
        else => std.debug.panic("wrong address for mapper: {x}", .{addr}),
    }
}
const BankSelect = packed struct (u8) {
    prgROMSelect: u3 = 0, // Select 32 KB PRG ROM bank for CPU $8000-$FFFF
    _: u1 = 0,
    vramSelect:u1 = 0, // Select 1 KB VRAM page for all 4 nametables
    __:u3 = 0,
};
pub fn write(ptr: *anyopaque, addr: u16, data: u8) void {
    const m: *AxRom = @ptrCast(@alignCast(ptr));
    // const m: *AxRom = @alignCast(@fieldParentPtr("interface", self));
    // return self.writeFn(self.ptr, addr, data);
    switch (addr) {
        // usually cartridge ram when present
        0x6000...0x7FFF => {
            std.debug.print(">AxRom write on 0x{x}, value: 0x{x}", .{ addr, data });
            // m.currentBank = data & 0b0000111; //@as(u3, @truncate(data));
        },
        0x8000...0xFFFF => {
            m.bankSelect = @bitCast(data);
        },
        else => {
            // m.currentBank = data & 0b00000111; // at least mgs does this..
        }, // std.debug.panic("wrong address for mapper: 0x{x}", .{addr}),
    }
}

pub fn ppu_read(ptr: *anyopaque, addr: u14) u8 {
    const m: *AxRom = @ptrCast(@alignCast(ptr));
        switch (addr) {
            0x0000...0x1FFF => return if (m.chrROM.len == 0) m.chrRAM[addr] else m.chrROM[addr],
            //// 2kb of internal ram, but 4kb of name pages
            0x2000...0x23FF => return m.vram[@as(u32,m.bankSelect.vramSelect)*1024 + addr - 0x2000],
            0x2400...0x27FF => return m.vram[@as(u32,m.bankSelect.vramSelect)*1024 + addr - 0x2400],
            0x2800...0x2BFF => return m.vram[@as(u32,m.bankSelect.vramSelect)*1024 + addr - 0x2800],
            0x2C00...0x2FFF => return m.vram[@as(u32,m.bankSelect.vramSelect)*1024 + addr - 0x2C00],
            else => @panic("boo"),
        }
}

pub fn ppu_write(ptr: *anyopaque, addr: u14, data: u8) void {
    const m: *AxRom = @ptrCast(@alignCast(ptr));
        switch (addr) {
            0x0000...0x1FFF => m.chrRAM[addr] = data, // 8kb of chrRAM
            //// 2kb of internal ram, but 4kb of name pages
            0x2000...0x23FF => m.vram[@as(u32,m.bankSelect.vramSelect)*1024 + addr - 0x2000] = data,
            0x2400...0x27FF => m.vram[@as(u32,m.bankSelect.vramSelect)*1024 + addr - 0x2400] = data,
            0x2800...0x2BFF => m.vram[@as(u32,m.bankSelect.vramSelect)*1024 + addr - 0x2800] = data,
            0x2C00...0x2FFF => m.vram[@as(u32,m.bankSelect.vramSelect)*1024 + addr - 0x2C00] = data,
            else => std.debug.panic("(write) wrong vram address: 0x{x}", .{addr}),
        }
}


pub fn serialize(ptr: *anyopaque, writer: *std.Io.Writer) !void {
    const m: *AxRom = @ptrCast(@alignCast(ptr));
    try writer.writeByte(@bitCast(m.bankSelect));
    try writer.writeAll(m.chrRAM);
    
}
pub fn deserialize(ptr: *anyopaque, reader: *std.Io.Reader) !void {
    const m: *AxRom = @ptrCast(@alignCast(ptr));
    m.bankSelect = @bitCast(try reader.takeByte());
    var writer = std.Io.Writer.fixed(m.chrRAM);
    try reader.streamExact(&writer, m.chrRAM.len);
    // std.debug.assert(n == m.chrRAM.len);
    // const slice = try reader.take(m.chrRAM.len);
    // @memcpy(m.chrRAM, slice);
}
pub fn byteSize(ptr: *anyopaque) u64 {
    const m: *AxRom = @ptrCast(@alignCast(ptr));
    return 1 + m.chrRAM.len;
}

pub fn onScanline(_: *anyopaque) bool {
    return false;
}
