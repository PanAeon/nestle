const Mapper = @import("Mapper.zig");
const NametableArragnment = Mapper.NametableArragnment;
const std = @import("std");
const MMC3 = @This();

const BankSelect = packed struct {
    bankRegister: u3, // which bank register to update on the next write
    _: u2,
    M: u1,
    //     0: $8000-$9FFF swappable,
    //        $C000-$DFFF fixed to second-last bank;
    //     1: $C000-$DFFF swappable,
    //        $8000-$9FFF fixed to second-last bank)
    PrgROMBankMode: u1,
    CHRA12Inversion: u1
};


prgROM: []u8,
chrROM: []u8,
prgRAM: [8*1024]u8,
vram: []u8,
nametableArrangement: NametableArragnment,
bankSelect : BankSelect,
bankValues: [8]u8,
irqLatch: u8,
irqCounter: u8,
irqEnabled: bool,

pub fn create(gpa: std.mem.Allocator, prgROM: []u8, chrROM: []u8, vram: []u8, nametableArrangement: NametableArragnment) !*MMC3 {
    var mmc3 = try gpa.create(Mapper.MMC3);
    mmc3.prgROM = prgROM;
    mmc3.chrROM = chrROM;
    mmc3.prgRAM = std.mem.zeroes([8*1024]u8);
    mmc3.vram = vram;
    mmc3.nametableArrangement = nametableArrangement;
    mmc3.bankSelect = std.mem.zeroes(BankSelect);
    mmc3.bankValues = std.mem.zeroes([8]u8);
    mmc3.irqLatch = 255;
    mmc3.irqCounter = 255;
    mmc3.irqEnabled = false;
    return mmc3;
}

pub fn destroy(ptr: *anyopaque, gpa: std.mem.Allocator) void {
    const m: *MMC3 = @ptrCast(@alignCast(ptr));
    gpa.free(m.prgROM);
    gpa.free(m.chrROM);
    gpa.destroy(m);
}

pub fn interface(self: *MMC3) Mapper {
    return .{
        .ptr = self,
        .vtable = &.{
            .read = read,
            .write = write,
            .ppu_read = ppu_read, 
            .ppu_write = ppu_write, 
            .destroy = destroy,
            .serialize = serialize,
            .deserialize = deserialize,
            .byteSize = byteSize,
            .onScanline = onScanline
        },
    };
}


pub fn read(ptr: *anyopaque, addr: u16) u8 {
    const m: *MMC3 = @ptrCast(@alignCast(ptr));
    switch (addr) {
        0x6000...0x7FFF => return m.prgRAM[addr - 0x6000],
        0x8000...0x9FFF => {
            if (m.bankSelect.PrgROMBankMode == 0) {
              return m.prgROM[@as(u32, m.bankValues[6]) * 8 * 1024 + @as(u32, addr) - 0x8000];
            } else {
                return m.prgROM[m.prgROM.len - (2*8*1024) + addr - 0x8000];
            }
        },
        0xA000...0xBFFF => {
            return m.prgROM[@as(u32, m.bankValues[7]) * 8 * 1024 + @as(u32, addr) - 0xA000];
        },
        0xC000...0xDFFF => {
            if (m.bankSelect.PrgROMBankMode == 0) {
                return m.prgROM[m.prgROM.len - (2*8*1024) + @as(u32, addr) - 0xC000];
            } else {
              return m.prgROM[@as(u32, m.bankValues[6]) * 8 * 1024 + @as(u32, addr) - 0xC000];
            }
        },
        0xE000...0xFFFF => { // 8 KB PRG ROM bank, fixed to the last bank
            return m.prgROM[m.prgROM.len - (8*1024) + @as(u32, addr) - 0xE000];
        },
        else => {
            // return 0; // open bus?
            std.debug.panic("wrong address for mmc3: 0x{x}", .{addr});
        } 
    }
}

pub fn write(ptr: *anyopaque, addr: u16, data: u8) void {
    const m: *MMC3 = @ptrCast(@alignCast(ptr));
    // std.debug.print("write: addr 0x{x}, data: {d}\n", .{addr, data});
    switch (addr) {
        0x6000...0x7FFF => {
            m.prgRAM[addr - 0x6000] = data;
        },
        0x8000...0x9FFF => {
            if (addr & 0x1 == 0) {
               m.bankSelect = @bitCast(data);
            } else {
               m.bankValues[m.bankSelect.bankRegister] = @bitCast(data);
            }
        },
        0xA000...0xBFFF => {
            if (addr & 0x1 == 0) {
               if (!(m.nametableArrangement == .FourScreens)) {
                    if (data & 0x1 == 0) {
                        m.nametableArrangement = .Horizontal;
                    } else {
                        m.nametableArrangement = .Vertical;
                    }
               }
            } else {
//                PRG RAM protect ($A001-$BFFF, odd)
            }
        },
        0xC000...0xDFFE => {
            if (addr & 0x1 == 0) {
                m.irqLatch = data;
            } else {
                m.irqCounter = m.irqLatch;
                // irq reload <- clears the MMC3 IRQ counter immediately,
            }
        },
        0xE000...0xFFFF => {
            if (addr & 0x1 == 0) {
                // irq disable
                //  disable MMC3 interrupts AND acknowledge any pending interrupts.
                m.irqEnabled = false;
            } else {
                m.irqEnabled = true;
               // irq enable
            }
        },
        else => {
          std.debug.panic("wrong address for MMC3: 0x{x}", .{addr});
            // m.currentBank = data & 0b00000111; // at least mgs does this..
        }, // 
    }
}

    // PPU $0000-$07FF (or $1000-$17FF): 2 KB switchable CHR bank
    // PPU $0800-$0FFF (or $1800-$1FFF): 2 KB switchable CHR bank
    // PPU $1000-$13FF (or $0000-$03FF): 1 KB switchable CHR bank
    // PPU $1400-$17FF (or $0400-$07FF): 1 KB switchable CHR bank
    // PPU $1800-$1BFF (or $0800-$0BFF): 1 KB switchable CHR bank
    // PPU $1C00-$1FFF (or $0C00-$0FFF): 1 KB switchable CHR bank
pub fn chr_address(self: *MMC3, addr: u14) u32 {
    if (self.bankSelect.CHRA12Inversion == 0) {
        switch (addr) {
            0x0000...0x07FF => return (@as(u32, (0xFE) & self.bankValues[0])*1024) + addr, 
            0x0800...0x0FFF => return @as(u32, (0xFE) & self.bankValues[1])*1024 + addr - 0x0800, 
            0x1000...0x13FF => return @as(u32, self.bankValues[2])*1024 + addr - 0x1000, 
            0x1400...0x17FF => return @as(u32, self.bankValues[3])*1024 + addr - 0x1400, 
            0x1800...0x1BFF => return @as(u32, self.bankValues[4])*1024 + addr - 0x1800, 
            0x1C00...0x1FFF => return @as(u32, self.bankValues[5])*1024 + addr - 0x1C00, 
            else => @panic("boo")
        }
    } else {
        switch (addr) {
            0x0000...0x03FF => return @as(u32, self.bankValues[2])*1024 + addr, //r2
            0x0400...0x07FF => return @as(u32, self.bankValues[3])*1024 + addr - 0x0400, // r3
            0x0800...0x0BFF => return @as(u32, self.bankValues[4])*1024 + addr - 0x0800, // r4
            0x0C00...0x0FFF =>  return @as(u32, self.bankValues[5])*1024 + addr - 0x0C00, // r5
            0x1000...0x17FF =>  return @as(u32, (0xFE) & self.bankValues[0])*1024 + addr - 0x1000, // r0
            0x1800...0x1FFF => return @as(u32, (0xFE) & self.bankValues[1])*1024 + addr - 0x1800,  // r1
            else => @panic("boo")
        }
    }
}

pub fn ppu_read(ptr: *anyopaque, addr: u14) u8 {
    const m: *MMC3 = @ptrCast(@alignCast(ptr));
    switch (m.nametableArrangement) {
        .Horizontal => switch (addr) {
            0x0000...0x1FFF => return m.chrROM[m.chr_address(addr)],
            //// 2kb of internal ram, but 4kb of name pages
            0x2000...0x23FF => return m.vram[addr - 0x2000],
            0x2400...0x27FF => return m.vram[addr - 0x2000],
            0x2800...0x2BFF => return m.vram[addr - 0x2800],
            0x2C00...0x2FFF => return m.vram[addr - 0x2800],
            else => @panic("boo"),
        },
        .Vertical => switch (addr) {
            0x0000...0x1FFF => return m.chrROM[m.chr_address(addr)],
            //// 2kb of internal ram, but 4kb of name pages
            0x2000...0x23FF => return m.vram[addr - 0x2000],
            0x2400...0x27FF => return m.vram[addr - 0x2400],
            0x2800...0x2BFF => return m.vram[addr - 0x2400],
            0x2C00...0x2FFF => return m.vram[addr - 0x2800],
            else => @panic("boo"),
        },
        .FourScreens => switch (addr) {
            0x2000...0x2FFF => return m.chrROM[m.chr_address(addr)],
            else => @panic("boo"),
        },
        else => std.debug.panic("unsupported mirroring by MMC3 {any}", .{m.nametableArrangement}),
    }
}

pub fn ppu_write(ptr: *anyopaque, addr: u14, data: u8) void {
    const m: *MMC3 = @ptrCast(@alignCast(ptr));
    switch (m.nametableArrangement) {
        .Horizontal => switch (addr) {
            0x0000...0x1FFF => {},
            //// 2kb of internal ram, but 4kb of name pages
            0x2000...0x23FF => m.vram[addr - 0x2000] = data,
            0x2400...0x27FF => m.vram[addr - 0x2000] = data,
            0x2800...0x2BFF => m.vram[addr - 0x2800] = data,
            0x2C00...0x2FFF => m.vram[addr - 0x2800] = data,
            else => @panic("boo"),
        },
        .Vertical => switch (addr) {
            0x0000...0x1FFF => {},
            //// 2kb of internal ram, but 4kb of name pages
            0x2000...0x23FF => m.vram[addr - 0x2000] = data,
            0x2400...0x27FF => m.vram[addr - 0x2400] = data,
            0x2800...0x2BFF => m.vram[addr - 0x2400] = data,
            0x2C00...0x2FFF => m.vram[addr - 0x2800] = data,
            else => @panic("boo"),
        },
        .FourScreens => switch (addr) {
            0x0000...0x1FFF => {},
            0x2000...0x2FFF => m.vram[addr - 0x2000] = data,
            else => @panic("boo"),
        },
        else => std.debug.panic("unsupported mirroring by MMC3 {any}", .{m.nametableArrangement}),
    }
}
pub fn onScanline(ptr: *anyopaque) bool {
    const m: *MMC3 = @ptrCast(@alignCast(ptr));
    if (m.irqCounter > 0) {
        m.irqCounter -=1;
    } else {
        m.irqCounter = m.irqLatch;
        if (m.irqEnabled) {
            return true;
        }
    }
    return false;
}


pub fn serialize(ptr: *anyopaque, writer: *std.Io.Writer) !void {
    const m: *MMC3 = @ptrCast(@alignCast(ptr));
    try writer.writeAll(&m.prgRAM);
    try writer.writeByte(@intFromEnum(m.nametableArrangement));
    try writer.writeByte(@bitCast(m.bankSelect));
    try writer.writeAll(&m.bankValues);
    try writer.writeByte(m.irqLatch);
    try writer.writeByte(m.irqCounter);
    try writer.writeByte(@intFromBool(m.irqEnabled));
}
pub fn deserialize(ptr: *anyopaque, reader: *std.Io.Reader) !void {
    const m: *MMC3 = @ptrCast(@alignCast(ptr));
    const slice = try reader.take(m.prgRAM.len);
    @memcpy(&m.prgRAM, slice);
    m.nametableArrangement = @enumFromInt(try reader.takeByte());
    m.bankSelect = @bitCast(try reader.takeByte());
    const slice2 = try reader.take(8);
    @memcpy(&m.bankValues, slice2);
    m.irqLatch = try reader.takeByte();
    m.irqCounter = try reader.takeByte();
    m.irqEnabled = try reader.takeByte() == 1;
}
pub fn byteSize(ptr: *anyopaque) u64 {
    _ = &ptr;
    return 8*1024+1+1+8+1+1+1;
}
