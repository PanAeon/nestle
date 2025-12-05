const std = @import("std");
const MemoryController = @import("core/MemoryController.zig");
const Cpu = @import("core/Cpu.zig");
const Apu = @import("core/Apu.zig");
const Ppu = @import("core/Ppu.zig");
const Controller = @import("core/Controller.zig");
const UxRom = @import("mapper/UxRom.zig");
const NRom = @import("mapper/NRom.zig");
const Mapper = @import("mapper/Mapper.zig");
const ines = @import("loader/ines.zig");
// FIXME: what happens when I copy emulator?
const Emulator = @This();

vram: [2048]u8,
// mapper:UxRom, 
mapper:NRom, 
rom: []u8,
chRom: []u8,
chram: []u8,
apu: Apu,
ppu: Ppu,
controller: Controller,
memoryController: MemoryController,
cpu: Cpu,
pub fn init(gpa: std.mem.Allocator, outputBuffer: []u32, emu: *Emulator) !void {
    // var f = try std.fs.openFileAbsolute("/foo/snes/Total.Recall.nes", .{});
    var f = try std.fs.openFileAbsolute("/foo/snes/testroms/palette_fill.nes", .{});
    defer f.close();
    // _ = try nestle.ines.hasMagicByte(&f);
    const romInfo = try ines.readRom(gpa, &f);
    emu.* = Emulator{
        .rom = romInfo.prgROM,
        .vram = std.mem.zeroes([2048]u8),
        .chram = try gpa.alloc(u8, 0x2000), // 8kb
        .chRom = romInfo.chrROM,
        .mapper = undefined,
        .apu = undefined,
        .ppu = undefined,
        .controller = undefined,
        .memoryController = undefined,
        .cpu = undefined 
    };
    for (emu.chram) |*b| {
        b.* = 0;
    }
    emu.mapper = NRom.init(romInfo.prgROM, 
        romInfo.chrROM,
        emu.chram, 
        &emu.vram, 
        Mapper.Mirroring.Horizontal); // FIXME: mirroring

    // _ = std.fs.File.writer(file: File, buffer: []u8)
    // emu.mapper = UxRom.init(romInfo.prgROM, 
    //     romInfo.chrROM,
    //     emu.chram, 
    //     &emu.vram, 
    //     Mapper.Mirroring.Horizontal); // FIXME: mirroring
    emu.apu = Apu.init();
    emu.ppu = Ppu.init(emu.mapper.interface(), outputBuffer);
    emu.controller = Controller.init();
    emu.memoryController = MemoryController{ 
        .mapper = emu.mapper.interface(),
        .apu = &emu.apu,
        .ppu = &emu.ppu,
        .controller = &emu.controller
    };
    emu.ppu.memoryController = &emu.memoryController;
    emu.cpu = Cpu.init(&emu.memoryController);
    const low: u16 = emu.memoryController.read(0xFFFC);
    const high: u16 = emu.memoryController.read(0xFFFD);
    emu.cpu.PC = low + (high * 256);

    // return emu;

    // for (0..60) |_| {
    //     // const before = try std.time.Instant.now();
    //     run_one_frame(&cpu, &ppu);
    //     // const after = try std.time.Instant.now();
    //     // const elapsed = after.since(before);
    //     // std.debug.print("elapsed ms: {d}\n", .{@as(f32, @floatFromInt(elapsed)) / 1000000.0});
    //
    //     cpu.print();
    //     std.debug.print("\n", .{});
    // }
    // std.debug.print("PPU: ctrl: {any} \nmask:{any}\n", .{ppu.ppuCtrl, ppu.ppuMask});
}

pub fn deinit(self: *Emulator, gpa: std.mem.Allocator) void {
    defer gpa.free(self.rom);
    defer gpa.free(self.chram);
    defer gpa.free(self.chRom);
}

pub fn setJoystickState(self: *Emulator, state: Controller.JoystickState) void {
    self.controller.joystick1 = state;
    // self.controller.joystick2 = state;
}

pub fn run_one_frame(self: *Emulator) void {
    const CpuFreq: f32 = 1789773.0; // 1.789 Mhz
    const FrameRate: f32 = 60.0;
    const CyclesPerFrame: usize = @intFromFloat(CpuFreq / FrameRate);
    const CyclesPerFrameActive: usize = CyclesPerFrame * 240 / 262;
    // const CyclesPerFrameBlank: usize = CyclesPerFrame - CyclesPerFrameActive;
    // const CpuAvgCycle: f32 = 3.0;
    // const CpuInstrperFrame : usize = @as(usize, CyclesPerFrame / CpuAvgCycle);
    // const CpuInstrPerFrameActive: usize = CpuInstrperFrame * 240 / 262;
    // const CpuInstrPerFrameBlank: usize = CpuInstrperFrame - CpuInstrPerFrameActive;

    var cycles: usize = 0;
    self.ppu.ppuStatus.VBlank = false;
    while (cycles < CyclesPerFrameActive) {
        const instr = self.cpu.decode2(self.cpu.PC);
        cycles += self.cpu.interpret(instr);
    }
    // ppu draw frame
    self.ppu.drawFrame();
    self.ppu.ppuStatus.VBlank = true;
    if (self.ppu.ppuCtrl.VBlankNMIEnable) {
        self.cpu.nmi();
    }
    while (cycles < CyclesPerFrame) {
        const instr = self.cpu.decode2(self.cpu.PC);
        cycles += self.cpu.interpret(instr);
    }
    // std.debug.print("elapsed: {d} cycles\n", .{cycles});
}

pub fn run_until(self: *Emulator, pc: u16) usize {
    const CpuFreq: f32 = 1789773.0; // 1.789 Mhz
    const FrameRate: f32 = 60.0;
    const CyclesPerFrame: usize = @intFromFloat(CpuFreq / FrameRate);
    const CyclesPerFrameActive: usize = CyclesPerFrame * 240 / 262;
    // const CyclesPerFrameBlank: usize = CyclesPerFrame - CyclesPerFrameActive;
    // const CpuAvgCycle: f32 = 3.0;
    // const CpuInstrperFrame : usize = @as(usize, CyclesPerFrame / CpuAvgCycle);
    // const CpuInstrPerFrameActive: usize = CpuInstrperFrame * 240 / 262;
    // const CpuInstrPerFrameBlank: usize = CpuInstrperFrame - CpuInstrPerFrameActive;

    var totalCycles: usize = 0;
    while (true) {
        var cycles: usize = 0;
        self.ppu.ppuStatus.VBlank = 0;
        while (cycles < CyclesPerFrameActive) {
            const instr = self.cpu.decode2(self.cpu.PC);
            if (self.cpu.PC == pc) {
                return totalCycles + cycles;
            }
            cycles += self.cpu.interpret(instr);
        }
        // ppu draw frame
        self.ppu.ppuStatus.VBlank = 1;
        if (self.ppu.ppuCtrl.VBlankNMIEnable == 1) {
            self.cpu.nmi();
        }
        while (cycles < CyclesPerFrame) {
            const instr = self.cpu.decode2(self.cpu.PC);
            cycles += self.cpu.interpret(instr);
            if (self.cpu.PC == pc) {
                return totalCycles + cycles;
            }
        }
        totalCycles += cycles;
    }

}
