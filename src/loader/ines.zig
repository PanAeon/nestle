const std = @import("std");
const File = std.fs.File;
// REF: https://www.nesdev.org/wiki/INES
pub const FileReadError = error{FileTooShort};
pub const Flags6 = packed struct {
    nametableArragement: u1, // 0 vertical
    batteryBackedPRGRam: u1, // $6000-7FFF
    trainer: u1, // 512-byte trainer at $7000-$71FF
    alternativeNametableLayout: u1,
    lowerNybbleOfMapper: u4,
};
pub const Header = packed struct {
    prgRomSize: u8, //  in 16 KB units
    chrRomSize: u8, //  in 8 KB units, (value 0 means the board uses CHR RAM)
    flags6: Flags6,
    flags7: u8,
    flags8: u8,
    flags9: u8,
    flags10: u8,
};

pub fn hasMagicByte(f: *File) !bool {
    const magic: [4]u8 = .{ 0x4E, 0x45, 0x53, 0x1A };
    var buff: [4]u8 = std.mem.zeroes([4]u8);
    try f.seekTo(0);
    const read = try f.read(&buff);
    return (read == 4) and std.mem.eql(u8, &buff, &magic);
}
pub fn readHeader(f: *File) !Header {
    var buff: [16]u8 = std.mem.zeroes([16]u8);
    try f.seekTo(0);
    const nRead = try f.read(&buff);
    if (nRead != 16) {
        return error.FileTooShort;
    }
    var header: Header = undefined;
    @memcpy(@as([]u8, @ptrCast(&header)), buff[4..12]);
    return header;
}
pub const RomInfo = struct {
    prgROM: []u8,
    chrROM: []u8,
    mapper: u8,
    nametableArragement: u1
};
// std.ascii.hexEscape(bytes: []const u8, case: Case)
// memory owned by caller
pub fn readRom(allocator: std.mem.Allocator, f: *File) !RomInfo  {
    const header = try readHeader(f);
    if (header.flags6.trainer == 1) {
        // for now skip 512 bytes
        try f.seekBy(512);
    }
    var prgROM: []u8 = try allocator.alloc(u8, @as(usize, header.prgRomSize) * 16 * 1024);
    var nRead = try f.read(prgROM);
    if (nRead != @as(usize, header.prgRomSize) * 16 * 1024) {
        return error.FileTooShort;
    }
    std.debug.print("header: {any}\n", .{header});
    // const numBanks = header.prgRomSize;
    const firstBankData = prgROM[0..0x4000];
    _ = &firstBankData;
    
    var chrROM: []u8 = &.{};
    if (header.chrRomSize > 0) {
        chrROM = try allocator.alloc(u8, @as(usize, header.chrRomSize) * 8 * 1024);
        nRead = try f.read(prgROM);
        // if (nRead != @as(usize, header.prgRomSize) * 16 * 1024) {
        //     return error.FileTooShort;
        // }
    }
    // mapped into $8000-$BFFF
    //
    // const lastBankData = prgROM[7 * 0x4000 .. 8 * 0x4000]; //16kb we need;
    // std.debug.print("> last data {x}\n", .{lastBankData[0x4000 - 16 .. 0x4000]});

    // const low: u16 = lastBankData[0x3FFC];
    // const high: u16 = lastBankData[0x3FFD];
    // std.debug.print("> low 0x{x} high 0x{x}\n", .{ low, high });

    // const jmp = low + (high * 256);
    // std.debug.print("> address {d}, 0x{x}\n", .{ jmp, jmp });
    // std.debug.print("> data {x}\n", .{prgROM[0x1c196 .. 16 + 0x1c196]});
    // std.debug.print("> data {x}\n", .{prgROM[@as(u32, 0x10000) + jmp .. @as(u43, 0x10000) + jmp + 16]});
    // std.debug.print("> data {x}\n", .{lastBankData[jmp - 0xC000 .. jmp - 0xC000 + 16]});
    // // std.fmt.hexToBytes(u, input: []const u8)
    //        CPU $8000-$BFFF: 16 KB switchable PRG ROM bank
    //   CPU $C000-$FFFF: 16 KB PRG ROM bank, fixed to the last bank
    return .{ 
        .prgROM = prgROM,
        .chrROM = chrROM,
        .mapper = header.flags6.lowerNybbleOfMapper,
        .nametableArragement = header.flags6.nametableArragement
    };
}
// -------------------------------------------------------------
// 0x8000 .. 0xBFFF   16kb (or 0x4000 bytes)
