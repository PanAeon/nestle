const std = @import("std");

const Apu = @This();

const PulseChannel = packed struct {
    volume: u4 = 0, // envelope period
    constantVolume: bool = false,
    loopEnvelope: bool = false, // disable length counter
    duty: u2 = 0,
    shiftCount: u3 = 0,
    negative: bool = false,
    period: u3,
    sweepUnit: bool = false,
    timer: u11 = 0, // merge?
    lengthCounterLoad: u5 = 0,
};

const TriangleChannel = packed struct {
    linearCounterControl: u7 = 0, // linearCounterReloadValue
    lengthCounterDisable: bool = false,
    timer: u11 = 0,
    lengthCounterLoad: u5 = 0,
};

const NoiseChannel = packed struct {
    volume: u4 = 0, // envelope period
    constantVolume: bool = false,
    loopEnvelope: bool = false, // disable length counter
    __: u2 = 0,
    noisePeriod: u4 = 0,
    ___: u3 = 0,
    loopNoise: bool = false,
    _: u3 = 0,
    lengthCounterLoad: u5 = 0,
};
const DMCChannel = packed struct {
    frequencyIndex: u4 = 0,
    __: u2 = 0,
    loopSample: bool = false,
    irqEnable: bool = false,
    directLoad: u7 = 0,
    _: bool = false,
    sampleAddress: u8 = 0, // %11AAAAAA.AA000000
    sampleLength: u8 = 0, // %0000LLLL.LLLL0001
};

const Control = packed struct {
    lcPulse1: bool = false, // length counter
    lcPulse2: bool = false,
    lcTriangle: bool = false,
    lcNoise: bool = false,
    dmcEnable: bool = false,
    _: u3 = 0,
};
const Status = packed struct {
    lcPulse1: bool = false, // length counter status
    lcPulse2: bool = false,
    lcTriangle: bool = false,
    lcNoise: bool = false,
    dmcEnable: bool = false,
    _: u1 = 0,
    frameInterrupt: bool = false,
    dmcInterrupt: bool = false,
};

const FrameCounter = packed struct { _: u6 = 0, disableFrameInterrupt: bool = false, fiveFrameSequence: bool = false };

pulse1Channel: PulseChannel = std.mem.zeroes(PulseChannel),
pulse2Channel: PulseChannel = std.mem.zeroes(PulseChannel),
triangleChannel: TriangleChannel = std.mem.zeroes(TriangleChannel),
noiseChannel: NoiseChannel = std.mem.zeroes(NoiseChannel),
dmcChannel: DMCChannel = std.mem.zeroes(DMCChannel),
control: Control = std.mem.zeroes(Control),
status: Status = std.mem.zeroes(Status),
frameCounter: FrameCounter = .{},
pub fn init() Apu {
    return .{};
}

pub fn read(self: *Apu, addr: u16) u8 {
    std.debug.print("apu read: 0x{X}\n", .{addr});
    switch (addr) {
        0x4015 => return @bitCast(self.status),
        else => return 0, // maybe open bus?
    }
}

pub fn write(self: *Apu, addr: u16, data: u8) void {
    // std.debug.print("apu write: 0x{X}\n", .{addr});
    switch (addr) {
        0x4000...0x4003 => @as([*]u8, @ptrCast(&self.pulse1Channel))[addr - 0x4000] = data,
        0x4004...0x4007 => @as([*]u8, @ptrCast(&self.pulse2Channel))[addr - 0x4004] = data,
        0x4008...0x400B => @as([*]u8, @ptrCast(&self.triangleChannel))[addr - 0x4008] = data,
        0x400C...0x400F => @as([*]u8, @ptrCast(&self.noiseChannel))[addr - 0x400C] = data,
        0x4010...0x4013 => {
            @as([*]u8, @ptrCast(&self.dmcChannel))[addr - 0x4010] = data;
            // std.debug.print("dmc channel: {any}\n", .{self.dmcChannel});
        },
        0x4015 => self.control = @bitCast(data),
        0x4017 => {
            self.frameCounter = @bitCast(data);
            // std.debug.print("frame counter: {any}\n", .{self.frameCounter});
        },
        else => std.debug.panic("wrong address for APU 0x{x}", .{addr}),
    }
}
//2 CPU cycles = 1 APU cycle.

// pub fn debug_print(self: *Apu) void {
//     std.debug.print("{any}\n{any}\n{any}\n{any}\n{any}\n{any}\n{any}", .{self.pulse1Channel, self.pulse2Channel,
//       self.triangleChannel, self.noiseChannel, self.dmcChannel,
//       self.status, self.frameCounter});
// }
