const std = @import("std");
const MemoryController = @import("MemoryController.zig");

const Cpu = @This();
A: u8,
X: u8,
Y: u8,
PC: u16,
S: u8,
P: Flags, //processor status
SP: u8,

// internal
pageCrossed: u1,
irqFlag: u1,
nmiFlag: u1,

memory: *MemoryController,
dmaDone: bool,

pub fn init(memory: *MemoryController) Cpu {
    return .{ .A = 0, .X = 0, .Y = 0, .PC = 0, .S = 0, .P = Flags.empty(), .SP = 0xFF, .pageCrossed = 0x00, .irqFlag = 0, .nmiFlag = 0, .memory = memory, .dmaDone = false };
}
pub fn print(self: *Cpu) void {
    std.debug.print(
        \\regs: A:  0x{x}, X: 0x{x}, Y:  0x{x}
        \\      PC: 0x{x}, S: 0x{x}, SP: 0x{x}
        \\flags: {d}{d}{d}{d}{d}{d}{d}{d}
        \\       NV-BDIZC
        \\
    , .{ self.A, self.X, self.Y, self.PC, self.S, self.SP, self.P.Negative, self.P.Overflow, self.P.@"-", self.P.B, self.P.Decimal, self.P.InterrupDisable, self.P.Zero, self.P.Carry });
}

// STACK: $0100-$01FF, grows left

// MOS Technology 6502 emu
pub const InstructionName = enum {
    Invalid,
    ADC,
    AND,
    ASL,
    BCC,
    BCS,
    BEQ,
    BIT,
    BMI,
    BNE,
    BPL,
    BRK,
    BVC,
    BVS,
    CLC,
    CLD,
    CLI,
    CLV,
    CMP,
    CPX,
    CPY,
    DEC,
    DEX,
    DEY,
    EOR,
    INC,
    INX,
    INY,
    JMP,
    JSR,
    LDA,
    LDX,
    LDY,
    LSR,
    NOP,
    ORA,
    PHA,
    PHP,
    PLA,
    PLP,
    ROL,
    ROR,
    RTI,
    RTS,
    SBC,
    SEC,
    SED,
    SEI,
    STA,
    STX,
    STY,
    TAX,
    TAY,
    TSX,
    TXA,
    TXS,
    TYA,
    // illegal opcodes:
    SLO,
    RLA,
    SRE,
    RRA,
    SAX,
    LAX,
    DCP,
    ISC,
    ANC,
    ALR,
    ARR,
    XAA,
    AXS,
    AHX,
    SHY,
    SHX,
    TAS,
    LAS

};

pub const AddressingMode = enum { ZeroPageX, ZeroPageY, AbsoluteX, AbsoluteY, IndirectX, IndirectY, Implied, Accumulator, Immediate, ZeroPage, Absolute, Relative, Indirect };

pub const DecodedInstruction = struct {
    name: InstructionName,
    mode: AddressingMode,
    arg0: u8,
    arg1: u8,
    numBytes: u8,
    numCycles: u8,

    pub fn empty() DecodedInstruction {
        return .{ .name = .Invalid, .mode = .Implied, .arg0 = 0, .arg1 = 0, .numBytes = 0, .numCycles = 0 };
    }
};

pub const Flags = packed struct {
    Carry: u1,
    Zero: u1,
    InterrupDisable: bool,
    Decimal: u1,
    B: u1,
    @"-": u1,
    Overflow: u1,
    Negative: u1,
    pub fn empty() Flags {
        return .{ .Carry = 0, .Zero = 0, .InterrupDisable = false, .Decimal = 0, .B = 0, .@"-" = 1, .Overflow = 0, .Negative = 0 };
    }
};

comptime {
    if (@sizeOf(Flags) != 1) {
        @compileError("Flags should be 8 bits");
    }
}

pub const Opcode = struct { bytes: u8, mode: AddressingMode, instr: InstructionName, cycles: u8 };
// reference: https://www.nesdev.org/wiki/Instruction_reference
pub const opcodes = init: {
    var xs: [256]Opcode = std.mem.zeroes([256]Opcode);
    xs[0x69] = .{ .instr = .ADC, .bytes = 2, .mode = .Immediate, .cycles = 2 };
    xs[0x65] = .{ .instr = .ADC, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0x75] = .{ .instr = .ADC, .bytes = 2, .mode = .ZeroPageX, .cycles = 4 };
    xs[0x6D] = .{ .instr = .ADC, .bytes = 3, .mode = .Absolute, .cycles = 4 };
    xs[0x7D] = .{ .instr = .ADC, .bytes = 3, .mode = .AbsoluteX, .cycles = 4 };
    xs[0x79] = .{ .instr = .ADC, .bytes = 3, .mode = .AbsoluteY, .cycles = 4 };
    xs[0x61] = .{ .instr = .ADC, .bytes = 2, .mode = .IndirectX, .cycles = 6 };
    xs[0x71] = .{ .instr = .ADC, .bytes = 2, .mode = .IndirectY, .cycles = 5 };

    xs[0x29] = .{ .instr = .AND, .bytes = 2, .mode = .Immediate, .cycles = 2 };
    xs[0x25] = .{ .instr = .AND, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0x35] = .{ .instr = .AND, .bytes = 2, .mode = .ZeroPageX, .cycles = 4 };
    xs[0x2D] = .{ .instr = .AND, .bytes = 3, .mode = .Absolute, .cycles = 4 };
    xs[0x3D] = .{ .instr = .AND, .bytes = 3, .mode = .AbsoluteX, .cycles = 4 };
    xs[0x39] = .{ .instr = .AND, .bytes = 3, .mode = .AbsoluteY, .cycles = 4 };
    xs[0x21] = .{ .instr = .AND, .bytes = 2, .mode = .IndirectX, .cycles = 6 };
    xs[0x31] = .{ .instr = .AND, .bytes = 2, .mode = .IndirectY, .cycles = 5 };

    xs[0x0A] = .{ .instr = .ASL, .bytes = 1, .mode = .Accumulator, .cycles = 2 };
    xs[0x06] = .{ .instr = .ASL, .bytes = 2, .mode = .ZeroPage, .cycles = 5 };
    xs[0x16] = .{ .instr = .ASL, .bytes = 2, .mode = .ZeroPageX, .cycles = 6 };
    xs[0x0E] = .{ .instr = .ASL, .bytes = 3, .mode = .Absolute, .cycles = 6 };
    xs[0x1E] = .{ .instr = .ASL, .bytes = 3, .mode = .AbsoluteX, .cycles = 7 };

    xs[0x90] = .{ .instr = .BCC, .bytes = 2, .mode = .Relative, .cycles = 2 };
    xs[0xB0] = .{ .instr = .BCS, .bytes = 2, .mode = .Relative, .cycles = 2 };
    xs[0xF0] = .{ .instr = .BEQ, .bytes = 2, .mode = .Relative, .cycles = 2 };

    xs[0x24] = .{ .instr = .BIT, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0x2C] = .{ .instr = .BIT, .bytes = 3, .mode = .Absolute, .cycles = 4 };

    xs[0x30] = .{ .instr = .BMI, .bytes = 2, .mode = .Relative, .cycles = 2 };
    xs[0xD0] = .{ .instr = .BNE, .bytes = 2, .mode = .Relative, .cycles = 2 };
    xs[0x10] = .{ .instr = .BPL, .bytes = 2, .mode = .Relative, .cycles = 2 };

    xs[0x00] = .{ .instr = .BRK, .bytes = 2, .mode = .Implied, .cycles = 7 };

    xs[0x50] = .{ .instr = .BVC, .bytes = 2, .mode = .Relative, .cycles = 2 };
    xs[0x70] = .{ .instr = .BVS, .bytes = 2, .mode = .Relative, .cycles = 2 };

    xs[0x18] = .{ .instr = .CLC, .bytes = 1, .mode = .Implied, .cycles = 2 };
    xs[0xD8] = .{ .instr = .CLD, .bytes = 1, .mode = .Implied, .cycles = 2 };
    xs[0x58] = .{ .instr = .CLI, .bytes = 1, .mode = .Implied, .cycles = 2 };
    xs[0xB8] = .{ .instr = .CLV, .bytes = 1, .mode = .Implied, .cycles = 2 };

    xs[0xC9] = .{ .instr = .CMP, .bytes = 2, .mode = .Immediate, .cycles = 2 };
    xs[0xC5] = .{ .instr = .CMP, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0xD5] = .{ .instr = .CMP, .bytes = 2, .mode = .ZeroPageX, .cycles = 4 };
    xs[0xCD] = .{ .instr = .CMP, .bytes = 3, .mode = .Absolute, .cycles = 4 };
    xs[0xDD] = .{ .instr = .CMP, .bytes = 3, .mode = .AbsoluteX, .cycles = 4 };
    xs[0xD9] = .{ .instr = .CMP, .bytes = 3, .mode = .AbsoluteY, .cycles = 4 };
    xs[0xC1] = .{ .instr = .CMP, .bytes = 2, .mode = .IndirectX, .cycles = 6 };
    xs[0xD1] = .{ .instr = .CMP, .bytes = 2, .mode = .IndirectY, .cycles = 5 };

    xs[0xE0] = .{ .instr = .CPX, .bytes = 2, .mode = .Immediate, .cycles = 2 };
    xs[0xE4] = .{ .instr = .CPX, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0xEC] = .{ .instr = .CPX, .bytes = 3, .mode = .Absolute, .cycles = 4 };

    xs[0xC0] = .{ .instr = .CPY, .bytes = 2, .mode = .Immediate, .cycles = 2 };
    xs[0xC4] = .{ .instr = .CPY, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0xCC] = .{ .instr = .CPY, .bytes = 3, .mode = .Absolute, .cycles = 4 };

    xs[0xC6] = .{ .instr = .DEC, .bytes = 2, .mode = .ZeroPage, .cycles = 5 };
    xs[0xD6] = .{ .instr = .DEC, .bytes = 2, .mode = .ZeroPageX, .cycles = 6 };
    xs[0xCE] = .{ .instr = .DEC, .bytes = 3, .mode = .Absolute, .cycles = 6 };
    xs[0xDE] = .{ .instr = .DEC, .bytes = 3, .mode = .AbsoluteX, .cycles = 7 };

    xs[0xCA] = .{ .instr = .DEX, .bytes = 1, .mode = .Implied, .cycles = 2 };
    xs[0x88] = .{ .instr = .DEY, .bytes = 1, .mode = .Implied, .cycles = 2 };

    xs[0x49] = .{ .instr = .EOR, .bytes = 2, .mode = .Immediate, .cycles = 2 };
    xs[0x45] = .{ .instr = .EOR, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0x55] = .{ .instr = .EOR, .bytes = 2, .mode = .ZeroPageX, .cycles = 4 };
    xs[0x4D] = .{ .instr = .EOR, .bytes = 3, .mode = .Absolute, .cycles = 4 };
    xs[0x5D] = .{ .instr = .EOR, .bytes = 3, .mode = .AbsoluteX, .cycles = 4 };
    xs[0x59] = .{ .instr = .EOR, .bytes = 3, .mode = .AbsoluteY, .cycles = 4 };
    xs[0x41] = .{ .instr = .EOR, .bytes = 2, .mode = .IndirectX, .cycles = 6 };
    xs[0x51] = .{ .instr = .EOR, .bytes = 2, .mode = .IndirectY, .cycles = 5 };

    xs[0xE6] = .{ .instr = .INC, .bytes = 2, .mode = .ZeroPage, .cycles = 5 };
    xs[0xF6] = .{ .instr = .INC, .bytes = 2, .mode = .ZeroPageX, .cycles = 6 };
    xs[0xEE] = .{ .instr = .INC, .bytes = 3, .mode = .Absolute, .cycles = 6 };
    xs[0xFE] = .{ .instr = .INC, .bytes = 3, .mode = .AbsoluteX, .cycles = 7 };

    xs[0xE8] = .{ .instr = .INX, .bytes = 1, .mode = .Implied, .cycles = 2 };
    xs[0xC8] = .{ .instr = .INY, .bytes = 1, .mode = .Implied, .cycles = 2 };

    xs[0x4C] = .{ .instr = .JMP, .bytes = 3, .mode = .Absolute, .cycles = 3 };
    xs[0x6C] = .{ .instr = .JMP, .bytes = 3, .mode = .Indirect, .cycles = 5 };

    xs[0x20] = .{ .instr = .JSR, .bytes = 3, .mode = .Absolute, .cycles = 6 };

    xs[0xA9] = .{ .instr = .LDA, .bytes = 2, .mode = .Immediate, .cycles = 2 };
    xs[0xA5] = .{ .instr = .LDA, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0xB5] = .{ .instr = .LDA, .bytes = 2, .mode = .ZeroPageX, .cycles = 4 };
    xs[0xAD] = .{ .instr = .LDA, .bytes = 3, .mode = .Absolute, .cycles = 4 };
    xs[0xBD] = .{ .instr = .LDA, .bytes = 3, .mode = .AbsoluteX, .cycles = 4 };
    xs[0xB9] = .{ .instr = .LDA, .bytes = 3, .mode = .AbsoluteY, .cycles = 4 };
    xs[0xA1] = .{ .instr = .LDA, .bytes = 2, .mode = .IndirectX, .cycles = 6 };
    xs[0xB1] = .{ .instr = .LDA, .bytes = 2, .mode = .IndirectY, .cycles = 5 };

    xs[0xA2] = .{ .instr = .LDX, .bytes = 2, .mode = .Immediate, .cycles = 2 };
    xs[0xA6] = .{ .instr = .LDX, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0xB6] = .{ .instr = .LDX, .bytes = 2, .mode = .ZeroPageY, .cycles = 4 };
    xs[0xAE] = .{ .instr = .LDX, .bytes = 3, .mode = .Absolute, .cycles = 4 };
    xs[0xBE] = .{ .instr = .LDX, .bytes = 3, .mode = .AbsoluteY, .cycles = 4 };

    xs[0xA0] = .{ .instr = .LDY, .bytes = 2, .mode = .Immediate, .cycles = 2 };
    xs[0xA4] = .{ .instr = .LDY, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0xB4] = .{ .instr = .LDY, .bytes = 2, .mode = .ZeroPageX, .cycles = 4 };
    xs[0xAC] = .{ .instr = .LDY, .bytes = 3, .mode = .Absolute, .cycles = 4 };
    xs[0xBC] = .{ .instr = .LDY, .bytes = 3, .mode = .AbsoluteX, .cycles = 4 };

    xs[0x4A] = .{ .instr = .LSR, .bytes = 1, .mode = .Accumulator, .cycles = 2 };
    xs[0x46] = .{ .instr = .LSR, .bytes = 2, .mode = .ZeroPage, .cycles = 5 };
    xs[0x56] = .{ .instr = .LSR, .bytes = 2, .mode = .ZeroPageX, .cycles = 6 };
    xs[0x4E] = .{ .instr = .LSR, .bytes = 3, .mode = .Absolute, .cycles = 6 };
    xs[0x5E] = .{ .instr = .LSR, .bytes = 3, .mode = .AbsoluteX, .cycles = 7 };

    xs[0xEA] = .{ .instr = .NOP, .bytes = 1, .mode = .Implied, .cycles = 2 };

    xs[0x09] = .{ .instr = .ORA, .bytes = 2, .mode = .Immediate, .cycles = 2 };
    xs[0x05] = .{ .instr = .ORA, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0x15] = .{ .instr = .ORA, .bytes = 2, .mode = .ZeroPageX, .cycles = 4 };
    xs[0x0D] = .{ .instr = .ORA, .bytes = 3, .mode = .Absolute, .cycles = 4 };
    xs[0x1D] = .{ .instr = .ORA, .bytes = 3, .mode = .AbsoluteX, .cycles = 4 };
    xs[0x19] = .{ .instr = .ORA, .bytes = 3, .mode = .AbsoluteY, .cycles = 4 };
    xs[0x01] = .{ .instr = .ORA, .bytes = 2, .mode = .IndirectX, .cycles = 6 };
    xs[0x11] = .{ .instr = .ORA, .bytes = 2, .mode = .IndirectY, .cycles = 5 };

    xs[0x48] = .{ .instr = .PHA, .bytes = 1, .mode = .Implied, .cycles = 3 };
    xs[0x08] = .{ .instr = .PHP, .bytes = 1, .mode = .Implied, .cycles = 3 };
    xs[0x68] = .{ .instr = .PLA, .bytes = 1, .mode = .Implied, .cycles = 4 };
    xs[0x28] = .{ .instr = .PLP, .bytes = 1, .mode = .Implied, .cycles = 4 };

    xs[0x2A] = .{ .instr = .ROL, .bytes = 1, .mode = .Accumulator, .cycles = 2 };
    xs[0x26] = .{ .instr = .ROL, .bytes = 2, .mode = .ZeroPage, .cycles = 5 };
    xs[0x36] = .{ .instr = .ROL, .bytes = 2, .mode = .ZeroPageX, .cycles = 6 };
    xs[0x2E] = .{ .instr = .ROL, .bytes = 3, .mode = .Absolute, .cycles = 6 };
    xs[0x3E] = .{ .instr = .ROL, .bytes = 3, .mode = .AbsoluteX, .cycles = 7 };

    xs[0x6A] = .{ .instr = .ROR, .bytes = 1, .mode = .Accumulator, .cycles = 2 };
    xs[0x66] = .{ .instr = .ROR, .bytes = 2, .mode = .ZeroPage, .cycles = 5 };
    xs[0x76] = .{ .instr = .ROR, .bytes = 2, .mode = .ZeroPageX, .cycles = 6 };
    xs[0x6E] = .{ .instr = .ROR, .bytes = 3, .mode = .Absolute, .cycles = 6 };
    xs[0x7E] = .{ .instr = .ROR, .bytes = 3, .mode = .AbsoluteX, .cycles = 7 };

    xs[0x40] = .{ .instr = .RTI, .bytes = 1, .mode = .Implied, .cycles = 6 };
    xs[0x60] = .{ .instr = .RTS, .bytes = 1, .mode = .Implied, .cycles = 6 };

    xs[0xE9] = .{ .instr = .SBC, .bytes = 2, .mode = .Immediate, .cycles = 2 };
    xs[0xE5] = .{ .instr = .SBC, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0xF5] = .{ .instr = .SBC, .bytes = 2, .mode = .ZeroPageX, .cycles = 4 };
    xs[0xED] = .{ .instr = .SBC, .bytes = 3, .mode = .Absolute, .cycles = 4 };
    xs[0xFD] = .{ .instr = .SBC, .bytes = 3, .mode = .AbsoluteX, .cycles = 4 };
    xs[0xF9] = .{ .instr = .SBC, .bytes = 3, .mode = .AbsoluteY, .cycles = 4 };
    xs[0xE1] = .{ .instr = .SBC, .bytes = 2, .mode = .IndirectX, .cycles = 6 };
    xs[0xF1] = .{ .instr = .SBC, .bytes = 2, .mode = .IndirectY, .cycles = 5 };

    xs[0x38] = .{ .instr = .SEC, .bytes = 1, .mode = .Implied, .cycles = 2 };
    xs[0xF8] = .{ .instr = .SED, .bytes = 1, .mode = .Implied, .cycles = 2 };
    xs[0x78] = .{ .instr = .SEI, .bytes = 1, .mode = .Implied, .cycles = 2 };

    xs[0x85] = .{ .instr = .STA, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0x95] = .{ .instr = .STA, .bytes = 2, .mode = .ZeroPageX, .cycles = 4 };
    xs[0x8D] = .{ .instr = .STA, .bytes = 3, .mode = .Absolute, .cycles = 4 };
    xs[0x9D] = .{ .instr = .STA, .bytes = 3, .mode = .AbsoluteX, .cycles = 5 };
    xs[0x99] = .{ .instr = .STA, .bytes = 3, .mode = .AbsoluteY, .cycles = 5 };
    xs[0x81] = .{ .instr = .STA, .bytes = 2, .mode = .IndirectX, .cycles = 6 };
    xs[0x91] = .{ .instr = .STA, .bytes = 2, .mode = .IndirectY, .cycles = 6 };

    xs[0x86] = .{ .instr = .STX, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0x96] = .{ .instr = .STX, .bytes = 2, .mode = .ZeroPageY, .cycles = 4 };
    xs[0x8E] = .{ .instr = .STX, .bytes = 3, .mode = .Absolute, .cycles = 4 };

    xs[0x84] = .{ .instr = .STY, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    xs[0x94] = .{ .instr = .STY, .bytes = 2, .mode = .ZeroPageX, .cycles = 4 };
    xs[0x8C] = .{ .instr = .STY, .bytes = 3, .mode = .Absolute, .cycles = 4 };

    xs[0xAA] = .{ .instr = .TAX, .bytes = 1, .mode = .Implied, .cycles = 2 };
    xs[0xA8] = .{ .instr = .TAY, .bytes = 1, .mode = .Implied, .cycles = 2 };
    xs[0xBA] = .{ .instr = .TSX, .bytes = 1, .mode = .Implied, .cycles = 2 };
    xs[0x8A] = .{ .instr = .TXA, .bytes = 1, .mode = .Implied, .cycles = 2 };
    xs[0x9A] = .{ .instr = .TXS, .bytes = 1, .mode = .Implied, .cycles = 2 };
    xs[0x98] = .{ .instr = .TYA, .bytes = 1, .mode = .Implied, .cycles = 2 };

    // illegal opcodes:
    // xs[0x07] = .{ .instr = .SLO, .bytes = 2, .mode = .ZeroPage, .cycles = 3 };
    break :init xs;
};

pub fn decode(n: usize, buff: []const u8) DecodedInstruction {
    var decoded: DecodedInstruction = DecodedInstruction.empty();
    const instr = opcodes[buff[n]];
    if (instr.bytes == 0) {
        std.debug.panic("opcode {X} not implemented", .{buff[n]});
    }
    decoded.mode = instr.mode;
    decoded.name = instr.instr;
    decoded.numCycles = instr.cycles;
    decoded.numBytes = instr.bytes;
    if (instr.bytes > 1) {
        decoded.arg0 = buff[n + 1];
    }
    if (instr.bytes > 2) {
        decoded.arg1 = buff[n + 2];
    }
    return decoded;
}

pub fn decode2(self: *Cpu, addr: u16) DecodedInstruction {
    var decoded: DecodedInstruction = DecodedInstruction.empty();
    const o = self.memory.read(addr);
    const instr = opcodes[o];
    if (instr.bytes == 0) {
        std.debug.panic("opcode {X} not implemented, PC: 0x{x}", .{ o, addr });
    }
    decoded.mode = instr.mode;
    decoded.name = instr.instr;
    decoded.numCycles = instr.cycles;
    decoded.numBytes = instr.bytes;
    if (instr.bytes > 1) {
        decoded.arg0 = self.memory.read(addr + 1);
    }
    if (instr.bytes > 2) {
        decoded.arg1 = self.memory.read(addr + 2);
    }
    return decoded;
}

pub fn fetch(self: *Cpu, instr: DecodedInstruction) u8 {
    self.pageCrossed = 0;
    return switch (instr.mode) {
        .Immediate => instr.arg0,
        .ZeroPage => self.memory.read(instr.arg0),
        .ZeroPageX => self.memory.read(self.X +% instr.arg0),
        .ZeroPageY => self.memory.read(self.Y +% instr.arg0),
        .Absolute => self.memory.read(@as(u16, instr.arg0) + ((@as(u16, instr.arg1) << 8))),
        .AbsoluteX => brk: {
            if (@as(u16, self.X) + @as(u16, instr.arg0) > 0xFF) {
                self.pageCrossed = 1;
            }

            break :brk self.memory.read(@as(u16, self.X) + @as(u16, instr.arg0) + (@as(u16, instr.arg1) << 8));
        },
        .AbsoluteY => brk: {
            if (@as(u16, self.Y) + @as(u16, instr.arg0) > 0xFF) {
                self.pageCrossed = 1;
            }
            break :brk self.memory.read(@as(u16, self.Y) +% @as(u16, instr.arg0) +% (@as(u16, instr.arg1) << 8));
        },
        .IndirectX => brk: {
            // val = PEEK(PEEK((arg + X) % 256) + PEEK((arg + X + 1) % 256) * 256)
            const a1 = self.memory.read(self.X +% instr.arg0);
            const a2 = self.memory.read(self.X +% instr.arg0 +% 1);
            break :brk self.memory.read(@as(u16, a1) + (@as(u16, a2) << 8));
        },
        .IndirectY => brk: {
            // val = PEEK(PEEK(arg) + PEEK((arg + 1) % 256) * 256 + Y)
            const a1 = self.memory.read(instr.arg0);
            const a2 = self.memory.read(instr.arg0 +% 1);
            if (@as(u16, a1) + @as(u16, a2) > 0xFF) {
                self.pageCrossed = 1;
            }
            break :brk self.memory.read(@as(u16, a1) +% (@as(u16, a2) << 8) +% @as(u16, self.Y));
        },
        .Accumulator => self.A,
        .Relative => instr.arg0,
        .Implied => 0,
        .Indirect => 0,
        // else => std.debug.panic(" mode {any} not implemented", .{instr.mode})
    };
}

test "fetch should return immediate argument" {
    var instr = DecodedInstruction.empty();
    instr.mode = .Immediate;
    instr.arg0 = 93;
    var memory = MemoryController{};
    var cpu = Cpu.init(&memory);

    try std.testing.expect(fetch(instr, &cpu) == 93);
}

test "fetch should get zeropage argument" {
    var instr = DecodedInstruction.empty();
    instr.mode = .ZeroPage;
    instr.arg0 = 118;
    var memory = MemoryController{};
    memory.internalRam[118] = 17;
    var cpu = Cpu.init(&memory);

    try std.testing.expect(fetch(instr, &cpu) == 17);
}
test "fetch should get zeropagex" {
    var instr = DecodedInstruction.empty();
    instr.mode = .ZeroPageX;
    instr.arg0 = 118;
    var memory = MemoryController{};
    memory.internalRam[118 + 7] = 19;
    var cpu = Cpu.init(&memory);
    cpu.X = 7;

    try std.testing.expect(fetch(instr, &cpu) == 19);
}
test "fetch should get zeropagey with overflow" {
    var instr = DecodedInstruction.empty();
    instr.mode = .ZeroPageY;
    instr.arg0 = 255;
    var memory = MemoryController{};
    memory.internalRam[0] = 19;
    var cpu = Cpu.init(&memory);
    cpu.Y = 1;

    try std.testing.expect(fetch(instr, &cpu) == 19);
}
test "fetch should get absolute address" {
    var instr = DecodedInstruction.empty();
    instr.mode = .Absolute;
    instr.arg0 = 3;
    instr.arg1 = 1;
    var memory = MemoryController{};
    memory.internalRam[259] = 19;
    var cpu = Cpu.init(&memory);

    try std.testing.expect(fetch(instr, &cpu) == 19);
}
test "fetch should get indirectX address" {
    // val = PEEK(PEEK((arg + X) % 256) + PEEK((arg + X + 1) % 256) * 256)
    var instr = DecodedInstruction.empty();
    instr.mode = .IndirectX;
    instr.arg0 = 3;
    var memory = MemoryController{};
    memory.internalRam[3] = 10;
    memory.internalRam[4] = 2;
    memory.internalRam[522] = 19;
    var cpu = Cpu.init(&memory);

    try std.testing.expect(fetch(instr, &cpu) == 19);
}

pub fn store(self: *Cpu, instr: DecodedInstruction, value: u8) void {
    return switch (instr.mode) {
        .Immediate => {},
        .ZeroPage => self.memory.write(instr.arg0, value),
        .ZeroPageX => self.memory.write(self.X +% instr.arg0, value),
        .ZeroPageY => self.memory.write(self.Y +% instr.arg0, value),
        .Absolute => self.memory.write(@as(u16, instr.arg0) +% ((@as(u16, instr.arg1) << 8)), value),
        .AbsoluteX => self.memory.write(@as(u16, self.X) +% @as(u16, instr.arg0) +% ((@as(u16, instr.arg1) << 8)), value),
        .AbsoluteY => self.memory.write(@as(u16, self.Y) +% @as(u16, instr.arg0) +% ((@as(u16, instr.arg1) << 8)), value),
        .IndirectX => brk: {
            // val = PEEK(PEEK((arg + X) % 256) + PEEK((arg + X + 1) % 256) * 256)
            const a1 = self.memory.read(self.X +% instr.arg0);
            const a2 = self.memory.read(self.X +% instr.arg0 +% 1);
            break :brk self.memory.write(@as(u16, a1) + (@as(u16, a2) << 8), value);
        },
        .IndirectY => brk: {
            // val = PEEK(PEEK(arg) + PEEK((arg + 1) % 256) * 256 + Y)
            const a1 = self.memory.read(instr.arg0);
            const a2 = self.memory.read(instr.arg0 +% 1);
            break :brk self.memory.write(@as(u16, a1) + (@as(u16, a2) << 8) + @as(u16, self.Y), value);
        },
        .Accumulator => self.A = value,
        .Relative => {}, // ???instr.arg0, //?
        .Implied => {},
        .Indirect => {},

        // else => std.debug.panic(" mode {any} not implemented", .{instr.mode})
    };
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
pub fn setBit(number: anytype, n: comptime_int, v: u1) @TypeOf(number) {
    // Ensure n is within the bounds of the number's bit width
    comptime {
        if (n >= @typeInfo(@TypeOf(number)).int.bits) {
            @compileError("Bit index 'n' is out of bounds for the given number type.");
        }
    }

    const mask = @as(@TypeOf(number), 1) << n;

    if (v == 1) {
        return @as(@TypeOf(number), (number | mask));
    } else {
        return @as(@TypeOf(number), (number & ~mask));
    }
}
pub fn interpret(self: *Cpu, instr: DecodedInstruction) u8 {
    var cycles: u8 = instr.numCycles;
    self.PC += instr.numBytes;
    switch (instr.name) {
        .ADC => {
            const value = self.fetch(instr);
            cycles += self.pageCrossed;
            var res, const o1 = @addWithOverflow(self.A, value);
            res, const o2 = @addWithOverflow(res, self.P.Carry);
            self.P.Carry = o1 | o2;
            self.P.Zero = @intFromBool(res == 0);
            self.P.Overflow = @intFromBool((((res ^ self.A) &
                (res ^ value) & 0x80)) != 0);
            self.P.Negative = getBit(res, 7);
            self.A = @truncate(res);
        },
        .AND => {
            const value = self.fetch(instr);
            cycles += self.pageCrossed;
            self.A = self.A & value;
            self.P.Zero = @intFromBool(self.A == 0);
            self.P.Negative = getBit(self.A, 7);
        },
        .ASL => {
            const value = self.fetch(instr);
            const res = value << 1;
            self.P.Zero = @intFromBool(res == 0);
            self.P.Negative = getBit(res, 7);
            self.P.Carry = getBit(value, 7);
            self.store(instr, value);
            self.store(instr, res);
        },
        .BCC => {
            if (self.P.Carry == 0) {
                const offset: i32 = @as(i8, @bitCast(instr.arg0));
                const res: u16 = @intCast(@as(i32, self.PC) + offset);
                cycles += @intFromBool(@as(u8, @truncate(res)) == 0xFE);
                // if ((self.PC % 256) != (res % 256)) {
                //     cycles += 1;
                // }
                self.PC = res;
                cycles += 1;
            }
        },
        .BCS => {
            if (self.P.Carry == 1) {
                const offset: i32 = @as(i8, @bitCast(instr.arg0));
                const res: u16 = @intCast(@as(i32, self.PC) + offset);
                cycles += @intFromBool(@as(u8, @truncate(res)) == 0xFE);
                self.PC = res;
                cycles += 1;
            }
        },
        .BEQ => {
            if (self.P.Zero == 1) {
                const offset: i32 = @as(i8, @bitCast(instr.arg0));
                const res: u16 = @intCast(@as(i32, self.PC) + offset);
                cycles += @intFromBool(@as(u8, @truncate(res)) == 0xFE);
                self.PC = res;
                cycles += 1;
            }
        },
        .BIT => {
            const value = self.fetch(instr);
            const res = self.A & value;
            self.P.Zero = @intFromBool(res == 0);
            self.P.Negative = getBit(value, 7);
            self.P.Overflow = getBit(value, 6);
        },
        .BMI => {
            if (self.P.Negative == 1) {
                const offset: i32 = @as(i8, @bitCast(instr.arg0));
                const res: u16 = @intCast(@as(i32, self.PC) + offset);
                cycles += @intFromBool(@as(u8, @truncate(res)) == 0xFE);
                self.PC = res;
                cycles += 1;
            }
        },
        .BNE => {
            if (self.P.Zero == 0) {
                const offset: i32 = @as(i8, @bitCast(instr.arg0));
                const res: u16 = @intCast(@as(i32, self.PC) + offset);
                cycles += @intFromBool(@as(u8, @truncate(res)) == 0xFE);
                self.PC = res;
                cycles += 1;
            }
        },
        .BPL => {
            if (self.P.Negative == 0) {
                const offset: i32 = @as(i8, @bitCast(instr.arg0));
                const res: u16 = @intCast(@as(i32, self.PC) + offset);
                self.PC = res;
                cycles += 1;
            }
        },
        .BRK => {
            const highByte: u8 = @truncate(self.PC >> 8);
            const lowByte: u8 = @truncate(self.PC);
            self.memory.write(@as(u16, self.SP) + 0x0100, highByte);
            self.SP -%= 1;
            self.memory.write(@as(u16, self.SP) + 0x0100, lowByte);
            self.SP -%= 1;
            var flags: Flags = self.P;
            flags.B = 1;
            self.memory.write(@as(u16, self.SP) + 0x0100, @bitCast(flags));
            self.SP -%= 1;

            const low: u16 = self.memory.read(0xFFFE);
            const high: u16 = self.memory.read(0xFFFF);
            const value = low + (high << 8);
            self.PC = value; //0xFFFE;
        },
        .BVC => {
            if (self.P.Overflow == 0) {
                const offset: i32 = @as(i8, @bitCast(instr.arg0));
                const res: u16 = @intCast(@as(i32, self.PC) + offset);
                cycles += @intFromBool(@as(u8, @truncate(res)) == 0xFE);
                self.PC = res;
                cycles += 1;
            }
        },
        .BVS => {
            if (self.P.Overflow == 1) {
                const offset: i32 = @as(i8, @bitCast(instr.arg0));
                const res: u16 = @intCast(@as(i32, self.PC) + offset);
                cycles += @intFromBool(@as(u8, @truncate(res)) == 0xFE);
                self.PC = res;
                cycles += 1;
            }
        },
        .CLC => {
            self.P.Carry = 0;
        },
        .CLD => {
            self.P.Decimal = 0;
        },
        .CLI => {
            // The effect of changing this flag is delayed one instruction
            self.P.InterrupDisable = false;
        },
        .CLV => {
            self.P.Overflow = 0;
        },
        .CMP => {
            const value = self.fetch(instr);
            cycles += self.pageCrossed;
            const res = self.A -% value;
            self.P.Carry = @intFromBool(self.A >= value);
            self.P.Zero = @intFromBool(self.A == value);
            self.P.Negative = getBit(res, 7);
        },
        .CPX => {
            const value = self.fetch(instr);
            const res = self.X -% value;
            self.P.Carry = @intFromBool(self.X >= value);
            self.P.Zero = @intFromBool(self.X == value);
            self.P.Negative = getBit(res, 7);
        },
        .CPY => {
            const value = self.fetch(instr);
            const res = self.Y -% value;
            self.P.Carry = @intFromBool(self.Y >= value);
            self.P.Zero = @intFromBool(self.Y == value);
            self.P.Negative = getBit(res, 7);
        },
        .DEC => {
            const value = self.fetch(instr);
            const res = value -% 1;
            self.P.Zero = @intFromBool(res == 0);
            self.P.Negative = getBit(res, 7);
            self.store(instr, value);
            self.store(instr, res);
        },
        .DEX => {
            self.X -%= 1;
            self.P.Zero = @intFromBool(self.X == 0);
            self.P.Negative = getBit(self.X, 7);
        },
        .DEY => {
            self.Y -%= 1;
            self.P.Zero = @intFromBool(self.Y == 0);
            self.P.Negative = getBit(self.Y, 7);
        },
        .EOR => {
            const value = self.fetch(instr);
            cycles += self.pageCrossed;
            const res = self.A ^ value;
            self.P.Zero = @intFromBool(res == 0);
            self.P.Negative = getBit(res, 7);
            self.A = res;
        },
        .INC => {
            const value = self.fetch(instr);
            const res = value +% 1;
            self.P.Zero = @intFromBool(res == 0);
            self.P.Negative = getBit(res, 7);
            self.store(instr, value);
            self.store(instr, res);
        },
        .INX => {
            self.X +%= 1;
            self.P.Zero = @intFromBool(self.X == 0);
            self.P.Negative = getBit(self.X, 7);
        },
        .INY => {
            self.Y +%= 1;
            self.P.Zero = @intFromBool(self.Y == 0);
            self.P.Negative = getBit(self.Y, 7);
        },
        .JMP => {
            // Unfortunately, because of a CPU bug,
            // if this 2-byte variable has an address ending in $FF
            // and thus crosses a page, then the CPU fails to increment
            // the page when reading the second byte and thus reads
            // the wrong address. For example, JMP ($03FF) reads $03FF
            // and $0300 instead of $0400.
            // TODO: write unit test for this
            if (instr.mode == .Indirect) {
                var value: u16 = self.fetch(instr);
                const low = self.memory.read(@as(u16, instr.arg0) + (@as(u16, instr.arg1) << 8));
                const high =
                    if (instr.arg0 == 0xFF)
                        self.memory.read((@as(u16, instr.arg1) << 8))
                    else
                        self.memory.read(@as(u16, instr.arg0) + (@as(u16, instr.arg1) << 8) + 1);
                value = @as(u16, low) + ((@as(u16, high) << 8));
                self.PC = value;
            } else if (instr.mode == .Absolute) {
                self.PC = (@as(u16, instr.arg0) + ((@as(u16, instr.arg1) << 8)));
            }
        },
        .JSR => {
            const pc = self.PC - 1; //Notably, the return address on the stack points 1 byte before the start of the next instruction,
            const highByte: u8 = @truncate(pc >> 8);
            const lowByte: u8 = @truncate(pc);
            self.memory.write(@as(u16, self.SP) + 0x0100, highByte);
            self.SP -%= 1;
            self.memory.write(@as(u16, self.SP) + 0x0100, lowByte);
            self.SP -%= 1;
            self.PC = @as(u16, instr.arg0) + (@as(u16, instr.arg1) << 8);
        },
        .LDA => {
            const value = self.fetch(instr);
            cycles += self.pageCrossed;
            self.A = value;
            self.P.Zero = @intFromBool(value == 0);
            self.P.Negative = getBit(value, 7);
        },
        .LDX => {
            const value = self.fetch(instr);
            cycles += self.pageCrossed;
            self.X = value;
            self.P.Zero = @intFromBool(value == 0);
            self.P.Negative = getBit(value, 7);
        },
        .LDY => {
            const value = self.fetch(instr);
            cycles += self.pageCrossed;
            self.Y = value;
            self.P.Zero = @intFromBool(value == 0);
            self.P.Negative = getBit(value, 7);
        },
        .LSR => {
            const value = self.fetch(instr);
            const res = value >> 1;
            self.P.Zero = @intFromBool(res == 0);
            self.P.Negative = 0;
            self.P.Carry = getBit(value, 0);
            self.store(instr, value);
            self.store(instr, res);
        },
        .NOP => {},
        .ORA => {
            const value = self.fetch(instr);
            cycles += self.pageCrossed;
            const res = self.A | value;
            self.P.Zero = @intFromBool(res == 0);
            self.P.Negative = getBit(res, 7);
            self.A = res;
        },
        .PHA => {
            self.memory.write(@as(u16, self.SP) + 0x0100, self.A);
            self.SP -%= 1;
        },
        .PHP => {
            var flags: Flags = self.P;
            flags.B = 1;
            self.memory.write(@as(u16, self.SP) + 0x0100, @bitCast(flags));
            self.SP -%= 1;
        },
        .PLA => {
            self.SP +%= 1;
            self.A = self.memory.read(@as(u16, self.SP) + 0x0100);
            self.P.Zero = @intFromBool(self.A == 0);
            self.P.Negative = getBit(self.A, 7);
        },
        .PLP => {
            self.SP +%= 1;
            const res = self.memory.read(@as(u16, self.SP) + 0x0100);
            const prevB = self.P.B;
            const prev0 = self.P.@"-";
            self.P = @bitCast(res);
            self.P.B = prevB;
            self.P.@"-" = prev0;
        },
        .ROL => {
            const value = self.fetch(instr);
            const r = std.math.rotl(u8, value, 1);
            const res = setBit(r, 0, self.P.Carry);
            self.P.Zero = @intFromBool(res == 0);
            self.P.Negative = getBit(res, 7);
            self.P.Carry = getBit(value, 7);
            self.store(instr, value);
            self.store(instr, res);
        },
        .ROR => {
            const value = self.fetch(instr);
            const r = std.math.rotr(u8, value, 1);
            const res = setBit(r, 7, self.P.Carry);
            self.P.Zero = @intFromBool(res == 0);
            self.P.Negative = getBit(res, 7);
            self.P.Carry = getBit(value, 0);
            self.store(instr, value);
            self.store(instr, res);
        },
        .RTI => {
            self.SP +%= 1;
            const f = self.memory.read(@as(u16, self.SP) + 0x0100);
            self.SP +%= 1;
            const low = self.memory.read(@as(u16, self.SP) + 0x0100);
            self.SP +%= 1;
            const high = self.memory.read(@as(u16, self.SP) + 0x0100);
            const prevB = self.P.B;
            const prev0 = self.P.@"-";
            self.P = @bitCast(f);
            self.P.B = prevB;
            self.P.@"-" = prev0;
            self.PC = @as(u16, low) + (@as(u16, high) << 8);
        },
        .RTS => {
            self.SP +%= 1;
            const low = self.memory.read(@as(u16, self.SP) + 0x0100);
            self.SP +%= 1;
            const high = self.memory.read(@as(u16, self.SP) + 0x0100);
            self.PC = @as(u16, low) + (@as(u16, high) << 8);
            self.PC += 1;
        },
        .SBC => {
            const value = self.fetch(instr);
            cycles += self.pageCrossed;
            var res, const o1 = @subWithOverflow(self.A, value);
            res, const o2 = @subWithOverflow(res, ~self.P.Carry);

            self.P.Carry = ~(o1 | o2);
            self.P.Zero = @intFromBool(res == 0);
            self.P.Overflow = @intFromBool((((res ^ self.A) &
                (res ^ ~value) & 0x80)) != 0);
            self.P.Negative = getBit(res, 7);
            self.A = res;
        },
        .SEC => {
            self.P.Carry = 1;
        },
        .SED => {
            self.P.Decimal = 1;
        },
        .SEI => {
            self.P.InterrupDisable = true;
        },
        .STA => {
            self.store(instr, self.A);
        },
        .STX => {
            self.store(instr, self.X);
        },
        .STY => {
            self.store(instr, self.Y);
        },
        .TAX => {
            self.X = self.A;
            self.P.Zero = @intFromBool(self.X == 0);
            self.P.Negative = getBit(self.X, 7);
        },
        .TAY => {
            self.Y = self.A;
            self.P.Zero = @intFromBool(self.Y == 0);
            self.P.Negative = getBit(self.Y, 7);
        },
        .TSX => {
            self.X = self.SP;
            self.P.Zero = @intFromBool(self.X == 0);
            self.P.Negative = getBit(self.X, 7);
        },
        .TXA => {
            self.A = self.X;
            self.P.Zero = @intFromBool(self.A == 0);
            self.P.Negative = getBit(self.A, 7);
        },
        .TXS => {
            self.SP = self.X;
        },
        .TYA => {
            self.A = self.Y;
            self.P.Zero = @intFromBool(self.A == 0);
            self.P.Negative = getBit(self.A, 7);
        },
        else => @panic("not implemented"),
    }

    return cycles;
}

test "[interpreter] ADC basic carry" {
    var memory = MemoryController{};
    var instr = DecodedInstruction.empty();
    instr.name = .ADC;
    instr.mode = .Immediate;
    instr.arg0 = 180;
    var cpu = Cpu.init();

    cpu.A = 111;

    _ = interpret(instr, &cpu, &memory);

    try std.testing.expect(cpu.A == 35);
    try std.testing.expect(cpu.P.Carry == 1);
}

test "[interpreter] ADC sign" {
    var memory = MemoryController{};
    var cpu = Cpu.init();
    var instr = DecodedInstruction.empty();
    instr.name = .ADC;
    instr.mode = .Immediate;
    instr.arg0 = 240; // @bitCast(@as(i8, -113));

    cpu.A = 190; //@bitCast(@as(i8, -24));

    _ = interpret(instr, &cpu, &memory);

    try std.testing.expect(cpu.A == 174);
    try std.testing.expect(cpu.P.Negative == 1);
}

test "[interpreter] ADC signed overflow" {
    var memory = MemoryController{};
    var cpu = Cpu.init();
    var instr = DecodedInstruction.empty();
    instr.name = .ADC;
    instr.mode = .Immediate;
    instr.arg0 = 0x8f; //

    cpu.A = 0x8f; //@bitCast(@as(i8, -24));

    _ = interpret(instr, &cpu, &memory);
    // const ux : u8 = @bitCast(@as(i8, -10));
    // std.debug.print("{d}\n", .{ux});

    try std.testing.expect(cpu.A == 0x1e);
    try std.testing.expect(cpu.P.Overflow == 1);
}

pub fn irq(self: *Cpu) void {
    if (!self.P.InterrupDisable) {
        const highByte: u8 = @truncate(self.PC >> 8);
        const lowByte: u8 = @truncate(self.PC);
        self.memory.write(@as(u16, self.SP) + 0x0100, highByte);
        self.SP -%= 1;
        self.memory.write(@as(u16, self.SP) + 0x0100, lowByte);
        self.SP -%= 1;
        var flags: Flags = self.P;
        flags.B = 0;
        self.memory.write(@as(u16, self.SP) + 0x0100, @bitCast(flags));
        self.SP -%= 1;
        self.P.InterrupDisable = true;
        const low: u16 = self.memory.read(0xFFFE);
        const high: u16 = self.memory.read(0xFFFF);
        self.PC = low + (high << 8);
    }
}

pub fn nmi(self: *Cpu) void {
    const highByte: u8 = @truncate(self.PC >> 8);
    const lowByte: u8 = @truncate(self.PC);
    self.memory.write(@as(u16, self.SP) + 0x0100, highByte);
    self.SP -%= 1;
    self.memory.write(@as(u16, self.SP) + 0x0100, lowByte);
    self.SP -%= 1;
    var flags: Flags = self.P;
    flags.B = 0;
    self.memory.write(@as(u16, self.SP) + 0x0100, @bitCast(flags));
    self.SP -%= 1;
    // self.P.InterrupDisable = 1;
    const low: u16 = self.memory.read(0xFFFA);
    const high: u16 = self.memory.read(0xFFFB);
    self.PC = low + (high << 8);
}
