const std = @import("std");
const nestle = @import("nestle");
const MemoryController = nestle.core.MemoryController;
const Cpu = nestle.core.Cpu;
const Apu = nestle.core.Apu;
const Ppu = nestle.core.Ppu;
const Controller = nestle.core.Controller;

pub fn main() !void {
    // std.debug.print("opcode 0x00 {any}\n", .{opcodes[0]});
    // const buff = [_]u8{0xa9, 0x01, 0x8d, 0x00, 0x02, 0xa9, 0x05,
    // 0x8d, 0x01, 0x02, 0xa9, 0x08, 0x8d, 0x02, 0x02};
    // var n: u8 = 0;
    // while (n < buff.len) {
    //       const instr = decode(n, &buff);
    //       std.debug.print("instr: {any} \n", .{instr});
    //       n += instr.numBytes;
    // }

    // const instr : DecodedInstruction = .{
    //       .name = .ADC,
    //       .mode = .Immediate,
    //       .arg0 = 0,
    //       .arg1 = 0,
    //       .numBytes = 4,
    //       .numCycles = 6
    // };
    // var registers = Registers.empty();
    // _ = interpret(instr, &registers, &memoryController);
    var f = try std.fs.openFileAbsolute("/foo/snes/Total.Recall.nes", .{});
    _ = try nestle.ines.hasMagicByte(&f);
    // const r = try nestle.ines.readHeader(&f);
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const rom: []u8 = try nestle.ines.readRom(gpa, &f);
    defer gpa.free(rom);

    var outBuffer: [256 * 240 * 4]u8 = .{0} ** (256 * 240 * 4);
    // _ = std.fs.File.writer(file: File, buffer: []u8)
    var vram: [0x2000]u8 = std.mem.zeroes([0x2000]u8);
    var mapper = nestle.mapper.UxRom.init(rom, &vram);
    var apu = Apu.init();
    var ppu = Ppu.init(mapper.interface(), &outBuffer);
    var joystick = Controller.init();
    var mc = MemoryController{ .mapper = mapper.interface(), .apu = &apu, .ppu = &ppu, .controller = &joystick };
    ppu.memoryController = &mc;
    var cpu = Cpu.init(&mc);
    const low: u16 = mc.read(0xFFFC);
    const high: u16 = mc.read(0xFFFD);
    cpu.PC = low + (high * 256);

    // var totalCycles = run_until(&cpu, &ppu, 0xC638);// 3295 from here
    // cpu.print();
    // std.debug.print("ppu vblank: {d}\n", .{ppu.ppuCtrl.VBlankNMIEnable});
    // std.debug.print("total cycles: {d}\n\n", .{totalCycles});
    //
    // // 0xc5aa
    // totalCycles += run_until(&cpu, &ppu, 0xc639); // PC: 0xcba8 0xcba6 0xc189
    // cpu.print();
    // std.debug.print("ppu vblank: {d}\n", .{ppu.ppuCtrl.VBlankNMIEnable});
    // std.debug.print("total cycles: {d}\n\n", .{totalCycles});
    // const instr = cpu.decode2(cpu.PC);
    // std.debug.print("at: {any}\narg0: 0x{x}, arg1: 0x{x}\n", .{instr, instr.arg0, instr.arg1});
    //
    // PC: 0xc189 => 122570
    for (0..60) |_| {
        // const before = try std.time.Instant.now();
        run_one_frame(&cpu, &ppu);
        // const after = try std.time.Instant.now();
        // const elapsed = after.since(before);
        // std.debug.print("elapsed ms: {d}\n", .{@as(f32, @floatFromInt(elapsed)) / 1000000.0});

        cpu.print();
        std.debug.print("\n", .{});
    }
    std.debug.print("PPU: ctrl: {any} \nmask:{any}\n", .{ ppu.ppuCtrl, ppu.ppuMask });
    // std.debug.print(">> ({d},{d}):\tinstr: {any}\t{any}\t[{d}, {d}]\n", .{i, cycles, instr.name, instr.mode, instr.arg0, instr.arg1});
    // const N = 1000000;
    // var cycles: usize = 0;
    // for (0..N) |i| {
    //     const instr = Cpu.decode2(cpu.PC, &mc);
    //     const c = cpu.interpret(instr,  &mc);
    //     cycles += c;
    //
    //
    //     // if (i > N - 5) {
    //      std.debug.print(">> ({d},{d}):\tinstr: {any}\t{any}\t[{d}, {d}]\n", .{i, cycles, instr.name, instr.mode, instr.arg0, instr.arg1});
    //      cpu.print();
    //      std.debug.print("---\n", .{});
    //     // }
    // }
    // std.debug.print("\n>>numCycles: {d}\n", .{cycles});
}

fn run_one_frame(cpu: *Cpu, ppu: *Ppu) void {
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
    ppu.ppuStatus.VBlank = false;
    while (cycles < CyclesPerFrameActive) {
        const instr = cpu.decode2(cpu.PC);
        cycles += cpu.interpret(instr);
    }
    // ppu draw frame
    ppu.ppuStatus.VBlank = true;
    if (ppu.ppuCtrl.VBlankNMIEnable) {
        cpu.nmi();
    }
    while (cycles < CyclesPerFrame) {
        const instr = cpu.decode2(cpu.PC);
        cycles += cpu.interpret(instr);
    }
}

fn run_until(cpu: *Cpu, ppu: *Ppu, pc: u16) usize {
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
        ppu.ppuStatus.VBlank = 0;
        while (cycles < CyclesPerFrameActive) {
            const instr = cpu.decode2(cpu.PC);
            if (cpu.PC == pc) {
                return totalCycles + cycles;
            }
            cycles += cpu.interpret(instr);
        }
        // ppu draw frame
        ppu.ppuStatus.VBlank = 1;
        if (ppu.ppuCtrl.VBlankNMIEnable == 1) {
            cpu.nmi();
        }
        while (cycles < CyclesPerFrame) {
            const instr = cpu.decode2(cpu.PC);
            cycles += cpu.interpret(instr);
            if (cpu.PC == pc) {
                return totalCycles + cycles;
            }
        }
        totalCycles += cycles;
    }
}
