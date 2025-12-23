const std = @import("std");
const Mapper = @import("../mapper/Mapper.zig");
const Apu = @import("Apu.zig");
const Ppu = @import("Ppu.zig");
const OpenBus = @import("OpenBus.zig");
const Controller = @import("Controller.zig");
// const DMA = @import("DMA.zig");

// RP2A03 <- NTSC NES CPU chip (6502)
//         $FFFA–$FFFB: NMI vector, which points at an NMI handler
//        $FFFC–$FFFD: Reset vector, which points at code to initialize the NES chipset
//        $FFFE–$FFFF: IRQ/BRK vector, which may point at a mapper's interrupt handler
//            (or, less often, a handler for APU interrupts)
//        These vectors are supplied by the cartridge.
const MemoryController = @This();
internalRam: [2048]u8 = std.mem.zeroes([2048]u8),
mapper: Mapper,
apu: *Apu,
ppu: *Ppu,
openBus: OpenBus = .{},
// dma: DMA = .{},
controller: *Controller,
pub fn read(self: *MemoryController, address: u16) u8 {
    const res = switch (address) {
        0x0000...0x07FF => self.internalRam[address],
        0x0800...0x0FFF => self.internalRam[address - 0x0800],
        0x1000...0x17FF => self.internalRam[address - 0x1000],
        0x1800...0x1FFF => self.internalRam[address - 0x1800],

        0x2000...0x2007 => self.ppu.read(address),
        0x2008...0x3FFF => self.ppu.read((address % 8) + 0x2000),

        0x4000...0x4014 => self.openBus.read(address),
        0x4015 => self.apu.read(address), //SND channel and IRQ status
        0x4016 => self.controller.read(address),
        0x4017 => self.controller.read(address),
        0x4018...0x401F => 0, // test registers
        // unmapped
        0x4020...0x5FFF => self.mapper.read(address),
        // usually cartridge ram when present
        0x6000...0x7FFF => self.mapper.read(address),

        0x8000...0xFFFF => self.mapper.read(address),
    };
    self.openBus.lastRead = res;
    return res;
}
pub fn write(self: *MemoryController, address: u16, data: u8) void {
    switch (address) {
        0x0000...0x07FF => self.internalRam[address] = data,
        0x0800...0x0FFF => self.internalRam[address - 0x0800] = data,
        0x1000...0x17FF => self.internalRam[address - 0x1000] = data,
        0x1800...0x1FFF => self.internalRam[address - 0x1FFF] = data,

        0x2000...0x2007 => return self.ppu.write(address, data),
        0x2008...0x3FFF => return self.ppu.write((address % 8) + 0x2000, data),

        0x4000...0x4013 => return self.apu.write(address, data),
        0x4014 => self.ppu.oamdma(data), // DMA, Copy 256 bytes from $xx00-$xxFF into OAM via OAMDATA ($2004)
        0x4015 => return self.apu.write(address, data),
        0x4016 => self.controller.setStrobe(data),
        0x4017 => return self.apu.write(address, data), // frame counter control

        0x4018...0x401F => {}, // test registers
        // unmapped
        0x4020...0x5FFF => self.mapper.write(address, data),
        // usually cartridge ram when present
        0x6000...0x7FFF => self.mapper.write(address, data),

        0x8000...0xFFFF => self.mapper.write(address, data),
    }
}
pub fn byteSize(self: *MemoryController) u64 {
    _ = &self;
    return 2048;
}
pub fn serialize(self: *MemoryController, writer: *std.Io.Writer) !void {
    try writer.writeAll(&self.internalRam);
    // const end = pos + self.internalRam.len;
    // @memcpy(buffer[pos..end], &self.internalRam);
    // return end;
}
pub fn deserialize(self: *MemoryController, reader: *std.Io.Reader) !void  {
    var writer = std.Io.Writer.fixed(&self.internalRam);
    try reader.streamExact(&writer, self.internalRam.len);
    // std.debug.print("n: {d}\n", .{n});
    // std.debug.assert(n == self.internalRam.len);
    // const slice = try reader.take(self.internalRam.len);
    // @memcpy(&self.internalRam, slice);
}
