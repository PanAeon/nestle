const Mapper = @import("Mapper.zig");
const Mirroring = Mapper.Mirroring;
const std = @import("std");

// https://www.nesdev.org/wiki/MMC1
const MMC1 = @This();

const ControlRegister = packed struct {
//     Nametable arrangement: (0: one-screen, lower bank; 1: one-screen, upper bank;
//                2: horizontal arrangement ("vertical mirroring", PPU A10); 
//                3: vertical arrangement ("horizontal mirroring", PPU A11) )
    nametableArragement: u2 = 0, 
     // PRG-ROM bank mode (0, 1: switch 32 KB at $8000, ignoring low bit of bank number;
     //                     2: fix first bank at $8000 and switch 16 KB bank at $C000;
     //                     3: fix last bank at $C000 and switch 16 KB bank at $8000)
    prgBankMode:u2 = 3,
    // CHR-ROM bank mode (0: switch 8 KB at a time; 1: switch two separate 4 KB banks)
    vromSwitchSize: u1 = 0,  // swap 8k of vrom at ppu 0000, 1 - swap 4k of rom at $0000 and $1000
                         // 1024k carts: 0 - ignore 256k selection register, 1 - ack 256 sel reg.
};


const PrgBank = packed struct {
    // - Select 16 KB PRG-ROM bank (low bit ignored in 32 KB mode)
    p:u4 = 0, 
       // MMC1A:
       // 0: fixed bank affects A17..A14
       // 1: fixed bank only affects A16..A14, bit 3 directly controls A17 across the entire $8000-$FFFF address range
       // MMC1B:
       // 0: PRG-RAM enabled
       // 1: PRG-RAM disabled
       //
    r: u1 = 0 
};

prgROM: []u8,
chrROM: []u8,
prgRAM: []u8,
chrRAM: []u8,
lastBankNum: usize,
vram: []u8,
buffer: u5,
currentBit: u3,
controlRegister: ControlRegister,
chrBank0Register: u5,
chrBank1Register: u5,
prgBankRegister: PrgBank,

pub fn create(gpa: std.mem.Allocator, prgROM: []u8, chrROM: []u8,  chrRAM: []u8, vram: []u8, nametableArragement: Mirroring) !*MMC1 {
    var mmc1 = try gpa.create(MMC1);
    mmc1.prgROM = prgROM;
    mmc1.chrROM = chrROM;
    mmc1.chrRAM = chrRAM;
    mmc1.vram = vram;
    _ = &nametableArragement;
    // mmc1.nametableArragement = nametableArragement;
    // mmc1.firstBank = 0;
    mmc1.lastBankNum = (prgROM.len / (16*1024)) - 1;
    // mmc1.firstChrBank = 0;
    // mmc1.secondChrBank = 0;
    mmc1.prgRAM = try gpa.alloc(u8, 8*1024);
    mmc1.buffer = 0;
    mmc1.currentBit = 0;
    mmc1.controlRegister = .{};
    mmc1.chrBank0Register = 0;
    mmc1.chrBank1Register = 0;
    mmc1.prgBankRegister = .{};
    return mmc1;
}

pub fn destroy(ptr: *anyopaque, gpa: std.mem.Allocator) void {
    const m: *MMC1 = @ptrCast(@alignCast(ptr));
    gpa.free(m.prgROM);
    gpa.free(m.chrROM);
    gpa.free(m.prgRAM);
    gpa.free(m.chrRAM);
    gpa.destroy(m);
}

pub fn interface(self: *MMC1) Mapper {
    return .{
        .ptr = self,
        .vtable = &.{ .read = read, .write = write, .ppu_read = ppu_read, .ppu_write = ppu_write, .destroy = destroy },
    };
}

pub fn read(ptr: *anyopaque, addr: u16) u8 {
    const m: *MMC1 = @ptrCast(@alignCast(ptr));

    switch (addr) {
        // usually cartridge ram when present
        0x6000...0x7FFF => return m.prgRAM[addr - 0x6000], // TODO: make optional
        0x8000...0xBFFF => { // 16kb
            // std.debug.print("current bank: {d}\n", .{m.currentBank});
            switch (m.controlRegister.prgBankMode) {
            0,1 => {
                const bankNum = setBit(m.prgBankRegister.p,0,0);
                return m.prgROM[@as(u32, bankNum) * 0x8000 + @as(u32, addr) - 0x8000];
            },
            2 => return m.prgROM[@as(u32, addr)], // fix first bank at 0x8000
            3 => return m.prgROM[@as(u32, m.prgBankRegister.p) * 0x4000 + @as(u32, addr) - 0x8000],
            }
        },
        // CPU $C000-$FFFF: 16 KB PRG-ROM bank, either fixed to the last bank or switchable
        0xC000...0xFFFF => {
            switch (m.controlRegister.prgBankMode) {
            0,1 => {
                const bankNum = setBit(m.prgBankRegister.p,0,0);
                return m.prgROM[@as(u32, bankNum) * 0x8000 + @as(u32, addr) - 0x8000];
            },
            2 => return m.prgROM[@as(u32, m.prgBankRegister.p) * 0x4000 + @as(u32, addr) - 0xC000],
            3 => return m.prgROM[m.lastBankNum * 0x4000 + @as(u32, addr) - 0xC000],
            }
            // return m.prgROM[m.lastBank * 0x4000 + @as(u32, addr) - 0xC000];
        },
        else => std.debug.panic("wrong address for mapper: {x}", .{addr}),
    }

}
// FIXME: When the serial port is written to on consecutive cycles, it ignores every write after the first. 
//
// Writing a value with bit 7 set ($80 through $FF) to any address in $8000-$FFFF 
// clears the shift register to its initial state.
//  To change a register's value, the CPU writes five times with bit 7 clear and one bit of the 
//  desired value in bit 0 (starting with the low bit of the value).
pub fn write(ptr: *anyopaque, addr: u16, data: u8) void {
    const m: *MMC1 = @ptrCast(@alignCast(ptr));
    switch (addr) {
        // usually cartridge ram when present
        0x6000...0x7FFF =>  m.prgRAM[addr - 0x6000] = data, // TODO: make optional
        0x8000...0xFFFF => { // bits 14,13 matter
            if (getBit(data, 7) == 1) {
                m.currentBit = 0;
                m.buffer = 0;
                m.controlRegister.prgBankMode = 3;
            } else {
                const bit:u1 = @truncate(data & 0x1);
                m.buffer = setBit(m.buffer, m.currentBit, bit);

                m.currentBit += 1;

                if (m.currentBit == 5) {
                    // const a:u2 = @truncate((addr & 0x6000)>>13);
                    switch (addr) {
                        0x8000...0x9FFF => m.controlRegister = @bitCast(m.buffer),
                        0xA000...0xBFFF => m.chrBank0Register = m.buffer,
                        0xC000...0xDFFF => m.chrBank1Register = m.buffer,
                        0xE000...0xFFFF => m.prgBankRegister = @bitCast(m.buffer),
                        else => @panic("unreachable")
                    }
                    // std.debug.print("mmc1 setup called, control: {any}\nchr0: 0x{x}, chr1: 0x{x}\nprgbank: {any}\n", .{m.controlRegister, m.chrBank0Register, m.chrBank1Register, m.prgBankRegister});
                    m.currentBit = 0;
                    m.buffer = 0;
                }
            }
        },
        else => {
            // m.currentBank = data & 0b00000111; // at least mgs does this..
        }, // std.debug.panic("wrong address for mapper: 0x{x}", .{addr}),
    }
}

    // PPU $0000-$0FFF: 4 KB switchable CHR bank
    // PPU $1000-$1FFF: 4 KB switchable CHR bank
pub fn ppu_read(ptr: *anyopaque, addr: u14) u8 {
    const m: *MMC1 = @ptrCast(@alignCast(ptr));
    switch (addr) {
    0x0000...0x0FFF =>  {
        if (m.chrROM.len > 0) { // FIXME: ram also switchable!
          if (m.controlRegister.vromSwitchSize == 0) {
                    // swap 8k of ROM at ppu0000
            const reg = setBit(m.chrBank0Register, 0, 0);
              return m.chrROM[8*1024*@as(u32, reg) + addr];
          } else {
              return m.chrROM[4*1024*@as(u32, m.chrBank0Register) + addr];
          }
        } else {
            return m.chrRAM[addr];
        }
    },
    0x1000...0x1FFF =>  {
        if (m.chrROM.len > 0) {
          if (m.controlRegister.vromSwitchSize == 0) {
                    // swap 8k of ROM at ppu0000
              const reg = setBit(m.chrBank0Register, 0, 0);
              return m.chrROM[8*1024*@as(u32, reg) + addr];
          } else {
              return m.chrROM[4*1024*@as(u32, m.chrBank1Register) + addr - 0x1000];
          }
        } else {
            return m.chrRAM[addr];
        }
    },
    0x2000...0x2FFF => 
        switch (m.controlRegister.nametableArragement) {
        0 => switch (addr) { // one screen lower bank
            0x2000...0x23FF => return m.vram[addr - 0x2000],
            0x2400...0x27FF => return m.vram[addr - 0x2400],
            0x2800...0x2BFF => return m.vram[addr - 0x2800],
            0x2C00...0x2FFF => return m.vram[addr - 0x2C00],
            else => @panic("not reachable")
        },
        1 => switch (addr) { // one screen higher bank
            0x2000...0x23FF => return m.vram[addr - 0x2000 + 1024],
            0x2400...0x27FF => return m.vram[addr - 0x2400 + 1024],
            0x2800...0x2BFF => return m.vram[addr - 0x2800 + 1024],
            0x2C00...0x2FFF => return m.vram[addr - 0x2C00 + 1024],
            else => @panic("not reachable")
        },
        2 => switch (addr) {// vertical mirroring, PPU A10
            0x2000...0x23FF => return m.vram[addr - 0x2000],
            0x2400...0x27FF => return m.vram[addr - 0x2000],
            0x2800...0x2BFF => return m.vram[addr - 0x2800],
            0x2C00...0x2FFF => return m.vram[addr - 0x2800],
            else => @panic("not reachable")
        }, 
        3 => switch (addr) { //horizontal mirroring, PPU A11
            0x2000...0x23FF => return m.vram[addr - 0x2000],
            0x2400...0x27FF => return m.vram[addr - 0x2400],
            0x2800...0x2BFF => return m.vram[addr - 0x2400],
            0x2C00...0x2FFF => return m.vram[addr - 0x2800],
            else => @panic("not reachable")
        },
    },
    else => std.debug.panic("ppu read: wrong address for mapper: {x}", .{addr}),
    }
}

pub fn ppu_write(ptr: *anyopaque, addr: u14, data: u8) void {
    const m: *MMC1 = @ptrCast(@alignCast(ptr));
    switch (addr) {
    0x0000...0x0FFF =>  {
        if (m.chrROM.len > 0) { // FIXME: ram also switchable!
          if (m.controlRegister.vromSwitchSize == 0) {
                    // swap 8k of ROM at ppu0000
            const reg = setBit(m.chrBank0Register, 0, 0);
              m.chrROM[8*1024*@as(u32, reg) + addr] = data;
          } else {
              m.chrROM[4*1024*@as(u32, m.chrBank0Register) + addr] = data;
          }
        } else {
            m.chrRAM[addr] = data;
        }
    },
    0x1000...0x1FFF =>  {
        if (m.chrROM.len > 0) {
          if (m.controlRegister.vromSwitchSize == 0) {
                    // swap 8k of ROM at ppu0000
              const reg = setBit(m.chrBank0Register, 0, 0);
              m.chrROM[8*1024*@as(u32, reg) + addr] = data;
          } else {
              m.chrROM[4*1024*@as(u32, m.chrBank1Register) + addr - 0x1000] = data;
          }
        } else {
            m.chrRAM[addr] = data;
        }
    },
    0x2000...0x2FFF => 
        switch (m.controlRegister.nametableArragement) {
        0 => switch (addr) { // one screen lower bank
            0x2000...0x23FF => m.vram[addr - 0x2000] = data,
            0x2400...0x27FF => m.vram[addr - 0x2400] = data,
            0x2800...0x2BFF => m.vram[addr - 0x2800] = data,
            0x2C00...0x2FFF => m.vram[addr - 0x2C00] = data,
            else => @panic("not reachable")
        },
        1 => switch (addr) { // one screen higher bank
            0x2000...0x23FF => m.vram[addr - 0x2000 + 1024] = data,
            0x2400...0x27FF => m.vram[addr - 0x2400 + 1024] = data,
            0x2800...0x2BFF => m.vram[addr - 0x2800 + 1024] = data,
            0x2C00...0x2FFF => m.vram[addr - 0x2C00 + 1024] = data,
            else => @panic("not reachable")
        },
        2 => switch (addr) {// vertical mirroring, PPU A10
            0x2000...0x23FF => m.vram[addr - 0x2000] = data,
            0x2400...0x27FF => m.vram[addr - 0x2000] = data,
            0x2800...0x2BFF => m.vram[addr - 0x2800] = data,
            0x2C00...0x2FFF => m.vram[addr - 0x2800] = data,
            else => @panic("not reachable")
        }, 
        3 => switch (addr) { //horizontal mirroring, PPU A11
            0x2000...0x23FF => m.vram[addr - 0x2000] = data,
            0x2400...0x27FF => m.vram[addr - 0x2400] = data,
            0x2800...0x2BFF => m.vram[addr - 0x2400] = data,
            0x2C00...0x2FFF => m.vram[addr - 0x2800] = data,
            else => @panic("not reachable")
        },
    },
    else => {
        std.debug.panic("ppu write: wrong address for mapper: 0x{x}", .{addr});
        // const _addr = addr - 0x2400;
        // ppu_write(ptr, _addr, data);
    }, 
    }
}

pub fn getBit(number: anytype, n: comptime_int) u1 {
    // Ensure n is within the bounds of the number's bit width
    comptime {
        if (n >= @typeInfo(@TypeOf(number)).int.bits) {
            @compileError("Bit index 'n' is out of bounds for the given number type.");
        }
    }

    // Create a mask with the nth bit set
    const mask = @as(@TypeOf(number), 1) << n;

    // Perform bitwise AND and then right shift to get the bit's value
    return @as(u1, @truncate((number & mask) >> n));
}
pub fn setBit(number: anytype, n: u3, v: u1) @TypeOf(number) {
    // Ensure n is within the bounds of the number's bit width
    // comptime {
    //     if (n >= @typeInfo(@TypeOf(number)).int.bits) {
    //         @compileError("Bit index 'n' is out of bounds for the given number type.");
    //     }
    // }

    const mask = @as(@TypeOf(number), 1) <<| n;

    if (v == 1) {
        return @as(@TypeOf(number), (number | mask));
    } else {
        return @as(@TypeOf(number), (number & ~mask));
    }
}
