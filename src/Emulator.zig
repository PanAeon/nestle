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
const zaudio = @import("zaudio");
const Emulator = @This();

vram: [2048]u8,
mapper: Mapper,
apu: Apu,
ppu: Ppu,
controller: Controller,
memoryController: MemoryController,
cpu: Cpu,
printCore: bool,
pub fn init(gpa: std.mem.Allocator, outputBuffer: []u32, emu: *Emulator) !void {
    // var f = try std.fs.openFileAbsolute("/foo/snes/Top Gun (USA) (Rev A).nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/Castlevania.USA.nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/Darkwing Duck (USA).nes", .{});
     // var f = try std.fs.openFileAbsolute("/foo/snes/7-dmc_basics.nes", .{});
      // var f = try std.fs.openFileAbsolute("/foo/snes/Metroid (USA).nes", .{});
     // var f = try std.fs.openFileAbsolute("/foo/snes/zelda.nes", .{});
      // var f = try std.fs.openFileAbsolute("/foo/snes/Teenage Mutant Ninja Turtles (USA).nes", .{});
     // var f = try std.fs.openFileAbsolute("/foo/snes/Contra (USA).nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/Chip 'n Dale - Rescue Rangers (USA).nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/DuckTales (USA).nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/Mega Man (USA).nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/Commando (USA).nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/BattleCity (Japan).nes", .{});
     // var f = try std.fs.openFileAbsolute("/foo/snes/Balloon Fight (USA).nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/Metal Gear (USA).nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/Jurassic Park (USA).nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/thwaite.nes", .{});
    var f = try std.fs.openFileAbsolute("/foo/snes/Super Mario Bros. (World).nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/nestest.nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/sprite.nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/controller.nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/Total.Recall.nes", .{});
    // var f = try std.fs.openFileAbsolute("/foo/snes/testroms/palette_fill.nes", .{});
      // var f = try std.fs.openFileAbsolute("/foo/snes/Power Blade 2 (USA).nes", .{});
    defer f.close();
    // _ = try nestle.ines.hasMagicByte(&f);
    emu.* = Emulator{
        .vram = std.mem.zeroes([2048]u8),
        .mapper = undefined,
        .apu = undefined,
        .ppu = undefined,
        .controller = undefined,
        .memoryController = undefined,
        .cpu = undefined,
        .printCore = false
    };
    const romInfo = try ines.readRom(gpa, &f, &emu.vram);
    emu.mapper = romInfo.mapper;
    emu.printCore = false;

    emu.apu = try Apu.init(gpa);
    emu.ppu = Ppu.init(emu.mapper, outputBuffer);
    emu.controller = Controller.init();
    emu.memoryController = MemoryController{ .mapper = emu.mapper, .apu = &emu.apu, .ppu = &emu.ppu, .controller = &emu.controller };
    emu.ppu.memoryController = &emu.memoryController;
    emu.apu.memoryController = &emu.memoryController;
    emu.cpu = Cpu.init(&emu.memoryController);
    emu.ppu.cpu = &emu.cpu;
    const low: u16 = emu.memoryController.read(0xFFFC);
    const high: u16 = emu.memoryController.read(0xFFFD);
    emu.cpu.PC = low + (high * 256);
    emu.cpu.SP = 0xFD;
    emu.cpu.P.InterrupDisable = true; // ???
    emu.warmup();
    // std.debug.print("current bank: {d}", emu.mapper

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
    self.apu.deinit(gpa);
    self.mapper.destroy(gpa);
}

pub fn setJoystickState(self: *Emulator, state: Controller.JoystickState) void {
    self.controller.joystick1 = state;
    // self.controller.joystick2 = state;
}
pub fn warmup(self: *Emulator) void {
    const Cycles: usize = 29658;

    var cycles: usize = 0;
    while (cycles < Cycles) {
        const instr = self.cpu.decode2(self.cpu.PC);
        const c = self.cpu.interpret(instr);
        cycles += c;
    }
}
pub fn run_one_frame(self: *Emulator) void {
    const CpuFreq: f32 = 1789773.0; // 1.789 Mhz
    const FrameRate: f32 = 60.0;
    const CyclesPerFrame: usize = @intFromFloat(CpuFreq / FrameRate);
    // const CyclesPerFrameActive: usize = CyclesPerFrame * 240 / 262;
    // const CyclesPerFrameBlank: usize = CyclesPerFrame - CyclesPerFrameActive;
    // const CpuAvgCycle: f32 = 3.0;
    // const CpuInstrperFrame : usize = @as(usize, CyclesPerFrame / CpuAvgCycle);
    // const CpuInstrPerFrameActive: usize = CpuInstrperFrame * 240 / 262;
    // const CpuInstrPerFrameBlank: usize = CpuInstrperFrame - CpuInstrPerFrameActive;

    // if (!self.cpu.P.InterrupDisable) {
    //     self.cpu.irq(); // hmm
    // }
    var cycles: usize = 0;
    var ppuBudget: usize = 0;
    self.ppu.startNewFrame();
    while (cycles < CyclesPerFrame) {
        // self.ppu.sprites[0].attrs.behindBackground = true;
        // self.ppu.sprites[0].tileIdx = 0;
        if (self.printCore) {
            std.debug.print("------------\n", .{});
            self.cpu.print();
            self.printCore = false;
            var instr = self.cpu.decode2(self.cpu.PC);
            _ = self.cpu.interpret(instr);
            self.cpu.print();
            instr = self.cpu.decode2(self.cpu.PC);
            _ = self.cpu.interpret(instr);
            self.cpu.print();
            std.debug.print("first sprite: {any}\n", .{self.ppu.sprites[0]});
            std.debug.print("------------\n", .{});
        }
        const instr = self.cpu.decode2(self.cpu.PC);
        const c = self.cpu.interpret(instr);
        cycles += c;
        ppuBudget += 3*c;
        while (ppuBudget > 0) {
            self.ppu.run();
            ppuBudget -= 1;
        }
    }
    // self.apu.clock(10);
    // std.debug.print("elapsed: {d} cycles\n", .{cycles});
}
pub fn run_cpu_test(self: *Emulator) !void {
    var f = try std.fs.openFileAbsolute("/foo/snes/nestest.log", .{});
    defer f.close();
    var linebuffer = [_]u8{0} ** 1024;
    var threaded: std.Io.Threaded = .init_single_threaded;
    var reader_state = f.reader(threaded.io(), &linebuffer);
    var reader = &reader_state.interface;

    self.cpu.PC = 0xC000;
    self.cpu.P.InterrupDisable = 1;
    var cycles: u64 = 0;
    // while (cycles < 30000) {
    // }

    var i: u64 = 1;
    while (true) {
        const line = reader.takeDelimiterExclusive('\n') catch &.{};
        if (line.len == 0 or i == 5004) {
            break;
        }
        const ref_addr = try std.fmt.parseInt(u16, line[0..4], 16);
        if (ref_addr != self.cpu.PC) {
            std.debug.panic("oops on line: {d}\n ref: 0x{x}, our: 0x{x}", .{ i, ref_addr, self.cpu.PC });
        }
        const ref_a = try std.fmt.parseInt(u16, line[50..52], 16);
        if (ref_a != self.cpu.A) {
            std.debug.panic("oops on line: {d}\n ref: 0x{x}, our: 0x{x}", .{ i, ref_a, self.cpu.A });
        }
        const ref_sp = try std.fmt.parseInt(u16, line[71..73], 16);
        if (ref_sp != self.cpu.SP) {
            std.debug.panic("oops on line: {d}\n ref: 0x{x}, our: 0x{x}", .{ i, ref_sp, self.cpu.SP });
        }
        const ref_x = try std.fmt.parseInt(u16, line[55..57], 16);
        if (ref_x != self.cpu.X) {
            std.debug.panic("oops on line: {d}\n ref: 0x{x}, our: 0x{x}", .{ i, ref_x, self.cpu.X });
        }
        const ref_y = try std.fmt.parseInt(u16, line[60..62], 16);
        if (ref_y != self.cpu.Y) {
            std.debug.panic("oops on line: {d}\n ref: 0x{x}, our: 0x{x}", .{ i, ref_y, self.cpu.Y });
        }
        const ref_flags = try std.fmt.parseInt(u8, line[65..67], 16);
        if (ref_flags != @as(u8, @bitCast(self.cpu.P))) {
            const ref: Cpu.Flags = @bitCast(ref_flags);
            std.debug.panic("oops on line: {d}\n ref: 0x{any},\n our: 0x{any}\n", .{ i, ref, self.cpu.P });
        }
        const instr = self.cpu.decode2(self.cpu.PC);
        cycles += self.cpu.interpret(instr);
        //  const ref_cycles = try std.fmt.parseInt(u64, line[90..line.len-1],  10);
        // if (ref_cycles !=  cycles) {
        //     std.debug.panic("oops on line: {d}\n ref cycles: {d},\n our: {d}\n", .{i, ref_cycles, cycles});
        // }

        // std.debug.print("line: {s}\n", .{line});
        try reader.discardAll(1);
        i += 1;
    }
    std.debug.print("done, num cycles on 5004: {d}\n", .{cycles});
}

pub fn run_one_frame_old_good_one(self: *Emulator) void {
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
    // self.ppu.ppuStatus.sprite0Hit = true;
    // self.ppu.ppuStatus.
    if (!self.cpu.P.InterrupDisable) {
        self.cpu.irq(); // hmm
    }
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
    self.apu.clock(10);
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
pub fn printCPUCore(self: *Emulator) void {
    self.printCore = true;
}
