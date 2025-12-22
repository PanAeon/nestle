const std = @import("std");

const zaudio = @import("zaudio");
const DEVICE_FORMAT = zaudio.Format.float32;
const MemoryController = @import("MemoryController.zig");
const NesMixerNode = @import("audio/NesMixerNode.zig");
const RB = @import("audio/RingBuffer.zig");

const RingBuffer = RB.RingBufferConstructor(Command);

pub const standard_channel_map = enum(u32) {
    ma_standard_channel_map_microsoft,
    ma_standard_channel_map_alsa,
    ma_standard_channel_map_rfc3551, // Based off AIFF. */
    ma_standard_channel_map_flac,
    ma_standard_channel_map_vorbis,
    ma_standard_channel_map_sound4, // FreeBSD's sound(4). */
    ma_standard_channel_map_sndio, // www.sndio.org/tips.html */
};

extern fn ma_channel_map_init_standard(channel_map: standard_channel_map, channel: ?[*]zaudio.Channel, cap: usize, channels: u32) void;

const fCPU: f64 = 1789773.0; // NTSC
const CPUCyclesInPPUFrame = 29901;
const numCyclesInFrame = @as(u64, @intFromFloat(fCPU / DEVICE_SAMPLE_RATE)) + 1;
const LengthTable: [32]u8 = .{
    // |  0   1   2   3   4   5   6   7    8   9   A   B   C   D   E   F
    // +----------------------------------------------------------------
    10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14, // 00-0F
    12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30, // 10-1F
};

const DutyCycleSequence: [32]u8 = .{
    0, 1, 0, 0, 0, 0, 0, 0,
    0, 1, 1, 0, 0, 0, 0, 0,
    0, 1, 1, 1, 1, 0, 0, 0,
    1, 0, 0, 1, 1, 1, 1, 1,
};

const PulseChannel = struct {
    const SweepSetup = packed struct(u8) {
        shiftCount: u3 = 0,
        negative: bool = false,
        period: u3 = 0,
        enabled: bool = false,
    };
    const DutyCycleAndVolume = packed struct {
        volume: u4 = 0, // envelope period
        constantVolume: bool = false,
        lengthCounterHalt: bool = false, // loop envelope
        duty: u2 = 0,
    };
    const TimerAndLengthCounter = packed struct {
        timerHigh: u3 = 0,
        lengthCounterLoad: u5 = 0,
    };
    dutyCycleAndVolume: DutyCycleAndVolume = .{},
    sweepSetup: SweepSetup = .{},
    timerLow: u8 = 0,
    timerAndLengthCounter: TimerAndLengthCounter = .{},
    enabled: bool = false,
    t: u11 = 0,
    counter: u11 = 0,
    waveformPos: u3 = 0,
    lengthCounter: u8 = 0,
    envelopeCounter: u8 = 0,
    decayLevel: u4 = 0,
    startEnvelope: bool = false,
    sweepCounter: u8 = 0,
    num: u8,

    pub fn init(num: u8) PulseChannel {
        return .{ .num = num };
    }
    pub fn enable(self: *PulseChannel, on: bool) void {
        if (on) {
            self.enabled = true;
        } else {
            self.enabled = false;
            self.lengthCounter = 0;
        }
    }
    pub fn setDutyAndVolume(self: *PulseChannel, d: DutyCycleAndVolume) void {
        self.dutyCycleAndVolume = d;
        self.envelopeCounter = d.volume;
        self.startEnvelope = true;
    }
    pub fn setTimerLow(self: *PulseChannel, _timerLow: u8) void {
        self.timerLow = _timerLow;
        const t: u11 = _timerLow + (@as(u11, self.timerAndLengthCounter.timerHigh) << 8);
        self.t = t;
    }
    // Writing to $4003/$4007 reloads the length counter, restarts the envelope, and resets the phase of the pulse generator.
    pub fn setTimerHigh(self: *PulseChannel, _timerHigh: TimerAndLengthCounter) void {
        self.timerAndLengthCounter = _timerHigh;
        self.t = self.timerLow + (@as(u11, self.timerAndLengthCounter.timerHigh) << 8);
        if (self.enabled) {
            self.lengthCounter = LengthTable[_timerHigh.lengthCounterLoad];
            self.waveformPos = 0;
            self.envelopeCounter = self.dutyCycleAndVolume.volume;
            // The envelope is restarted, for pulse channels phase is reset, or triangle the linear counter reload flag is set.
        }
    }

    pub fn setSweep(self: *PulseChannel, sweep: SweepSetup) void {
        self.sweepSetup = sweep;
        self.sweepCounter = sweep.period; //  Sets the reload flag
    }

    pub fn clock(self: *PulseChannel) void {
        self.counter = (self.counter +% 1);
        if (self.counter > self.t) {
            self.counter = 0;
            self.waveformPos +%= 1;
        }
    }
    pub fn clockLengthAndSweep(self: *PulseChannel) void {
        if (!self.dutyCycleAndVolume.lengthCounterHalt and self.lengthCounter > 0) {
            self.lengthCounter -= 1;
        }
        if (self.sweepSetup.enabled) {
            if (self.sweepCounter > 0) {
                self.sweepCounter -= 1;
            } else {
                self.sweepCounter = self.sweepSetup.period;
                const t1 = self.t >> self.sweepSetup.shiftCount;
                if (self.sweepSetup.negative) {
                    if (self.num == 1) {
                        if (self.t >= t1 + 1) {
                            self.t = self.t - t1 - 1;
                        } else {
                            self.t = 0;
                        }
                    } else {
                        if (self.t >= t1) {
                            self.t = self.t - t1;
                        } else {
                            self.t = 0;
                        }
                    }
                } else {
                    self.t = self.t +% t1;
                }
            }
        }
    }
    pub fn clockEnvelope(self: *PulseChannel) void {
        if (!self.startEnvelope) {
            if (self.envelopeCounter > 0) {
                self.envelopeCounter -= 1;
            }
        } else {
            self.startEnvelope = false;
            self.decayLevel = 15;
            self.envelopeCounter = self.dutyCycleAndVolume.volume;
        }
        if (self.envelopeCounter == 0) {
            self.envelopeCounter = self.dutyCycleAndVolume.volume;
            if (self.decayLevel > 0) {
                self.decayLevel -= 1;
            } else {
                if (self.dutyCycleAndVolume.lengthCounterHalt) {
                    self.decayLevel = 15;
                }
            }
        }
    }
    pub fn output(self: *PulseChannel) u8 {
        const volume: u4 = if (self.dutyCycleAndVolume.constantVolume)
            self.dutyCycleAndVolume.volume
        else
            self.decayLevel;

        return @intFromBool(self.enabled) * @intFromBool(self.t > 8) * @intFromBool(self.lengthCounter > 0) *
            @intFromBool(self.t < 0x7FF) *
            (DutyCycleSequence[@as(u8, self.waveformPos) + 8 * @as(u8, self.dutyCycleAndVolume.duty)]) * volume;
    }
};

const TriangleSequence = [32]u4{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
const TriangleChannel = struct {
    const TimerAndLengthCounter = packed struct {
        timerHigh: u3 = 0,
        lengthCounterLoad: u5 = 0,
    };
    const LinearCounter = packed struct(u8) {
        linearCounterReloadValue: u7 = 0, // linearCounterControl
        lengthCounterHalt: bool = false,
    };
    linearCounter: LinearCounter = .{},
    timerAndLengthCounter: TimerAndLengthCounter = .{},
    timerLow: u8 = 0,
    enabled: bool = false,
    t: u11 = 0,
    counter: u11 = 0,
    waveformPos: u5 = 0,
    lengthCounter: u8 = 0,
    linearTimer: u7 = 0,
    pub fn init() TriangleChannel {
        return .{};
    }
    pub fn enable(self: *TriangleChannel, on: bool) void {
        if (on) {
            self.enabled = true;
        } else {
            self.enabled = false;
            self.lengthCounter = 0;
        }
    }
    pub fn setLinearCounter(self: *TriangleChannel, _counter: LinearCounter) void {
        self.linearCounter = _counter;
        self.linearTimer = _counter.linearCounterReloadValue;
    }
    pub fn setTimerLow(self: *TriangleChannel, _timerLow: u8) void {
        self.timerLow = _timerLow;
        self.t = _timerLow + (@as(u11, self.timerAndLengthCounter.timerHigh) << 8);
    }
    pub fn setTimerHigh(self: *TriangleChannel, _timerHigh: TimerAndLengthCounter) void {
        self.timerAndLengthCounter = _timerHigh;
        self.t = self.timerLow + (@as(u11, self.timerAndLengthCounter.timerHigh) << 8);
        self.lengthCounter = _timerHigh.lengthCounterLoad;
    }

    pub fn clock(self: *TriangleChannel) void {
        self.counter = (self.counter +% 1);
        if (self.counter >= self.t) {
            self.counter = 0;
            self.waveformPos +%= 1;
        }
    }
    pub fn clockLength(self: *TriangleChannel) void {
        if (!self.linearCounter.lengthCounterHalt and self.lengthCounter > 0) {
            self.lengthCounter -= 1;
        }
    }
    pub fn clockLinearCounter(self: *TriangleChannel) void {
        if (self.linearCounter.lengthCounterHalt) {
            self.linearTimer = self.linearCounter.linearCounterReloadValue;
        } else {
            if (self.linearTimer > 0) {
                self.linearTimer -= 1;
            }
        }
    }
    pub fn output(self: *TriangleChannel) u8 {
        return @intFromBool(self.enabled) * @intFromBool(self.lengthCounter > 0) *
            @intFromBool(self.linearTimer > 0) *
            (TriangleSequence[self.waveformPos]);
    }
};

const NoisePeriodTable = [16]u12{ 4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068 };
// https://www.nesdev.org/wiki/APU_Noise
const NoiseChannel = struct {
    const Volume = packed struct {
        volume: u4 = 0, // envelope period
        constantVolume: bool = false,
        lengthCounterHalt: bool = false, // loop envelope
        _: u2 = 0,
    };
    const Noise = packed struct(u8) {
        noisePeriod: u4 = 0,
        ___: u3 = 0,
        loopNoise: bool = false,
    };
    const LengthCounter = packed struct {
        _: u3 = 0,
        lengthCounterLoad: u5 = 0,
    };
    volume: Volume = .{},
    noise: Noise = .{},
    // lengthCounterLoad: u5 = 0,
    enabled: bool = false,
    length: u8 = 0,
    timerLow: u8 = 0,
    t: u12 = 0,
    counter: u11 = 0,
    lengthCounter: u8 = 0,
    envelopeCounter: u8 = 0,
    decayLevel: u4 = 0,
    startEnvelope: bool = false,
    shiftRegister: u15 = 1,

    pub fn init() NoiseChannel {
        return .{};
    }
    pub fn enable(self: *NoiseChannel, on: bool) void {
        if (on) {
            self.enabled = true;
        } else {
            self.enabled = false;
            self.length = 0;
        }
    }
    pub fn setVolume(self: *NoiseChannel, v: Volume) void {
        self.volume = v;
        self.startEnvelope = true;
    }

    pub fn setNoise(self: *NoiseChannel, n: Noise) void {
        self.noise = n;
        self.t = NoisePeriodTable[n.noisePeriod];
    }
    pub fn setLengthCounter(self: *NoiseChannel, c: LengthCounter) void {
        // self.lengthCounterLoad = c.lengthCounterLoad;
        self.lengthCounter = c.lengthCounterLoad;
        self.startEnvelope = true;
    }

    pub fn clock(self: *NoiseChannel) void {
        self.counter = (self.counter +% 2);
        if (self.counter > self.t) {
            self.counter = 0;
            // gen noise
            const feedback = if (self.noise.loopNoise)
                getBit(self.shiftRegister, 0) ^ getBit(self.shiftRegister, 6)
            else
                getBit(self.shiftRegister, 0) ^ getBit(self.shiftRegister, 1);
            self.shiftRegister >>= 1;
            self.shiftRegister = setBit(self.shiftRegister, 14, feedback);
        }
    }
    pub fn clockLength(self: *NoiseChannel) void {
        if (!self.volume.lengthCounterHalt and self.lengthCounter > 0) {
            self.lengthCounter -= 1;
        }
    }
    pub fn clockEnvelope(self: *NoiseChannel) void {
        if (!self.startEnvelope) {
            if (self.envelopeCounter > 0) {
                self.envelopeCounter -= 1;
            }
        } else {
            self.startEnvelope = false;
            self.decayLevel = 15;
            self.envelopeCounter = self.volume.volume;
        }
        if (self.envelopeCounter == 0) {
            self.envelopeCounter = self.volume.volume;
            if (self.decayLevel > 0) {
                self.decayLevel -= 1;
            } else {
                if (self.volume.lengthCounterHalt) {
                    self.decayLevel = 15;
                }
            }
        }
    }
    pub fn output(self: *NoiseChannel) u8 {
        const volume: u4 = if (self.volume.constantVolume)
            self.volume.volume
        else
            self.decayLevel;

        return @intFromBool(self.enabled) * @intFromBool(self.lengthCounter > 0) *
            (~getBit(self.shiftRegister, 0)) *
            volume;
    }
};

const DMCRate = [8]u11{ 428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54 };
const DMCChannel = struct {
    const FrequencyIndex = packed struct {
        rateIndex: u4 = 0,
        __: u2 = 0,
        loopSample: bool = false,
        irqEnable: bool = false,
    };
    const DirectLoad = packed struct {
        directLoad: u7 = 0,
        _: u1 = 0,
    };
    frequency: FrequencyIndex = .{},
    outputLevel: u7 = 0,
    sampleAddress: u16 = 0, // %11AAAAAA.AA000000
    sampleLength: u16 = 0, // %0000LLLL.LLLL0001
    enabled: bool = false,
    mc: *MemoryController = undefined,
    counter: u11 = 0,
    t: u11 = 0,

    currentAddress: u16 = 0,
    bytesRemaining: u16 = 0,
    sampleBuffer: u8 = 0,
    sampleBufferEmpty: bool = true,

    shift: u3 = 0,
    bitsRemaining: u8 = 0,
    silence: bool = true,

    pub fn init() DMCChannel {
        return .{};
    }

    pub fn setDirectLoad(self: *DMCChannel, dl: DirectLoad) void {
        self.outputLevel = dl.directLoad;
    }
    pub fn setFrequencyIndex(self: *DMCChannel, fi: FrequencyIndex) void {
        self.frequency = fi;
        self.t = DMCRate[fi.rateIndex];
    }
    pub fn setSampleAddress(self: *DMCChannel, addr: u8) void {
         self.sampleAddress = 0xC000 + (@as(u16, addr) * 64);
         self.currentAddress = self.sampleAddress;
         // std.debug.print("set sample address: 0x{x}\n", .{self.currentAddress});
    }
    pub fn setSampleLength(self: *DMCChannel, l: u8) void {
       self.sampleLength = @as(u16, l) * 16 + 1;
       // std.debug.print("set sample length: {d}\n", .{self.sampleLength});
       self.bytesRemaining = self.sampleLength;
    }

    pub fn enable(self: *DMCChannel, on: bool) void {
        if (on == self.enabled) {
            return;
        } else {
            if (on) {
                self.enabled = true;
                self.loadSampleBufer();
            } else {
                self.enabled = false;
                self.bytesRemaining = 0;
            }
        }
    }
    // cpu is stalled for 1-4CPU cycles..
    pub fn loadSampleBufer(self: *DMCChannel) void {
       if (self.bytesRemaining > 0) {
         // std.debug.print("address: 0x{x}\n", .{ self.currentAddress });
         self.sampleBuffer = self.mc.read(self.currentAddress);
         self.sampleBufferEmpty = false;
         self.currentAddress += 1;
         self.bytesRemaining -=1;
         if (self.bytesRemaining == 0 and self.frequency.loopSample) {
           self.currentAddress = self.sampleAddress;
           self.bytesRemaining = self.sampleLength;
         }
         if (self.currentAddress > 0xFFFF) {
           self.currentAddress -= 0x3fff; 
         }
       }
    }
    pub fn clockOutput(self: *DMCChannel) void {
        if (!self.silence) {
            const bit: u1 = @truncate(self.sampleBuffer >> self.shift);
            if (bit == 1) {
                if (self.outputLevel <= 125) {
                    self.outputLevel += 2;
                }
            } else {
                if (self.outputLevel >= 2) {
                    self.outputLevel -= 2;
                }
            }
            if (self.shift == 7) {
                self.shift = 0;
                self.loadSampleBufer();
            } else {
                self.shift += 1;
            }
        } else {}
        if (self.bitsRemaining > 0) {
            self.bitsRemaining -= 1;
        } else {
            self.bitsRemaining = 8;
            if (self.sampleBufferEmpty) {
                self.silence = true;
            } else {
                self.silence = false;
                self.shift = 0;
            }
            // output cycle ends I guess;
        }
    }
    pub fn clock(self: *DMCChannel) void {
        self.counter = (self.counter +% 2); // clocked in cpu cycles
        if (self.counter > self.t) {
            self.counter = 0;
            self.clockOutput();
        }
    }

    pub fn output(self: *DMCChannel) u7 {
        return self.outputLevel;
    }

};

const FrameCounterData = packed struct { _: u6 = 0, disableFrameInterrupt: bool = false, fiveFrameSequence: bool = false };
const FrameCounter = struct {
    fiveStepMode: bool = false,
    cycle: u64 = 0,

    // Envelopes & triangle's linear counter
    pub fn genQuaterFrame(self: *FrameCounter) bool {
        if (self.fiveStepMode) {
            return self.cycle == 3728 or self.cycle == 7456 or self.cycle == 11185 or self.cycle == 18640;
        } else {
            return self.cycle == 3728 or self.cycle == 7456 or self.cycle == 11185 or self.cycle == 14914;
        }
    }
    pub fn genHalfFrame(self: *FrameCounter) bool {
        if (self.fiveStepMode) {
            return self.cycle == 7456 or self.cycle == 18640;
        } else {
            return self.cycle == 7456 or self.cycle == 14914;
        }
    }
    pub fn clock(self: *FrameCounter) void {
        self.cycle += 1;
        if ((self.fiveStepMode and self.cycle >= 18641) or (!self.fiveStepMode and self.cycle >= 14915)) {
            self.cycle = 0;
        }
    }
};

const PulseTable: [31]f32 = brk: {
    var t: [31]f32 = .{0.0} ** 31;
    for (1..31) |i| {
        t[i] = 95.52 / (8128.0 / @as(f32, @floatFromInt(i)) + 100.0);
    }
    break :brk t;
};
const TndTable: [203]f32 = brk: {
    var t: [203]f32 = .{0.0} ** 203;
    for (1..203) |i| {
        t[i] = 163.67 / (24329.0 / @as(f32, @floatFromInt(i)) + 100);
    }
    break :brk t;
};
const NesDS = struct {
    ds: zaudio.DataSourceBase = std.mem.zeroes(zaudio.DataSourceBase),
    cpuCycle: u64 = 0,
    freq: f64 = 0.0,
    dutyCycle: f64 = 0.0,
    time: f64 = 0,
    advance: f64 = 0,
    rb: *RingBuffer,
    pulse1: PulseChannel,
    pulse2: PulseChannel,
    triangle: TriangleChannel,
    noise: NoiseChannel,
    dmc: DMCChannel,
    frameCounter: FrameCounter,

    pub fn calculateAdvance(sampleRate: f64, frequency: f64) f64 {
        return (1.0 / (sampleRate / frequency));
    }
    // pub fn calculateAdvance(period: u64) f64 {
    //     const freq = fCPU / @as(f64, @floatFromInt(period));
    //     return (1.0 / (DEVICE_SAMPLE_RATE / freq));
    // }

    pub fn create(allocator: std.mem.Allocator, rb: *RingBuffer) zaudio.Error!*NesDS {
        var ds = try allocator.create(NesDS);
        ds.time = 0.0;
        ds.rb = rb;
        // std.debug.print("num cyc: {d}\n", .{numCyclesInFrame});
        ds.cpuCycle = 0;
        ds.frameCounter = .{};
        ds.pulse1 = PulseChannel.init(1);
        ds.pulse2 = PulseChannel.init(2);
        ds.triangle = TriangleChannel.init();
        ds.noise = NoiseChannel.init();
        ds.dmc = DMCChannel.init();
        var dsConfig = zaudio.DataSource.Config.init();
        dsConfig.vtable = &vtable;
        _ = try zaudio.DataSource.create(dsConfig, &ds.ds);
        return ds;
    }
    pub fn setMemoryController(self: *NesDS, mc: *MemoryController) void {
        self.dmc.mc = mc;
    }

    pub fn destroy(handle: *NesDS, allocator: std.mem.Allocator) void {
        allocator.destroy(handle);
    }

    pub fn asDataSource(handle: *NesDS) *const zaudio.DataSource {
        return @as(*const zaudio.DataSource, @ptrCast(handle));
    }
    pub fn asDataSourceMut(handle: *NesDS) *zaudio.DataSource {
        return @as(*zaudio.DataSource, @ptrCast(handle));
    }

    const vtable: zaudio.DataSource.VTable = .{
        .onRead = onRead,
        .onSeek = onSeek, // noop
        .onGetDataFormat = onGetDataFormat,
        .onGetCursor = null,
        .onGetLength = null,
        .onSetLooping = null,
        .flags = .{},
    };

    pub fn handleWrite(self: *NesDS, address: u16, data: u8) void {
        switch (address) {
            0x4000 => self.pulse1.setDutyAndVolume(@bitCast(data)),
            0x4001 => self.pulse1.setSweep(@bitCast(data)),
            0x4002 => self.pulse1.setTimerLow(data),
            0x4003 => self.pulse1.setTimerHigh(@bitCast(data)),

            0x4004 => self.pulse2.setDutyAndVolume(@bitCast(data)),
            0x4005 => self.pulse2.setSweep(@bitCast(data)),
            0x4006 => self.pulse2.setTimerLow(data),
            0x4007 => self.pulse2.setTimerHigh(@bitCast(data)),

            0x4008 => self.triangle.setLinearCounter(@bitCast(data)),
            0x4009 => {},
            0x400A => self.triangle.setTimerLow(data),
            0x400B => self.triangle.setTimerHigh(@bitCast(data)),

            0x400C => self.noise.setVolume(@bitCast(data)),
            0x400D => {},
            0x400E => self.noise.setNoise(@bitCast(data)),
            0x400F => self.noise.setLengthCounter(@bitCast(data)),

            0x4010 => self.dmc.frequency = @bitCast(data),
            0x4011 => self.dmc.setDirectLoad(@bitCast(data)),
            0x4012 => self.dmc.setSampleAddress(data),
            0x4013 => self.dmc.setSampleLength(data),

            0x4015 => {
                const control: Control = @bitCast(data);
                self.pulse1.enable(control.lcPulse1);
                self.pulse2.enable(control.lcPulse2);
                self.triangle.enable(control.lcTriangle);
                self.noise.enable(control.lcNoise);
                self.dmc.enable(control.dmcEnable);
            },
            0x4017 => {
                const fc: FrameCounterData = @bitCast(data);
                self.frameCounter.fiveStepMode = fc.fiveFrameSequence;
                self.frameCounter.cycle = 18638;
                // std.debug.print("frame counter: {any}\n", .{self.frameCounter});
            },
            else => {},
        }
    }

    pub fn onRead(ds: *zaudio.DataSource, frames_out: ?*anyopaque, frame_count: u64, frames_read: *u64) callconv(.c) zaudio.Result {
        var self: *NesDS = @ptrCast(@alignCast(ds));
        // std.debug.print("rb len: {d}\n", .{self.rb.len()});
        if (frames_out) |_| {
            var pFramesOutF32: [*]f32 = @ptrCast(@alignCast(frames_out));
            for (0..frame_count) |i| {
                // std.debug.print("rb len: {d}\n", .{self.rb.data.len});
                // self.cpuCycle += numCyclesInFrame;
                for (0..numCyclesInFrame / 2) |_| {
                    self.cpuCycle += 2;
                    self.pulse1.clock();
                    self.pulse2.clock();
                    self.triangle.clock();
                    self.noise.clock();
                    self.dmc.clock();
                    self.frameCounter.clock();
                    if (self.frameCounter.genQuaterFrame()) {
                        // Envelopes & triangle's linear counter
                        self.pulse1.clockEnvelope();
                        self.pulse2.clockEnvelope();
                        self.triangle.clockLinearCounter();
                        self.noise.clockEnvelope();
                    }
                    if (self.frameCounter.genHalfFrame()) {
                        // Length counters & sweep units
                        self.pulse1.clockLengthAndSweep();
                        self.pulse2.clockLengthAndSweep();
                        self.triangle.clockLength();
                        self.noise.clockLength();
                    }
                    while (!self.rb.isEmpty() and self.rb.peekAssumeLength().cycle < self.cpuCycle) {
                        const command = self.rb.readAssumeLength();
                        self.handleWrite(command.address, command.data);
                    }
                }
                if (self.cpuCycle > CPUCyclesInPPUFrame) {
                    self.cpuCycle = 0;
                    if (!self.rb.isEmpty() and self.rb.peekAssumeLength().cycle == 32000) {
                        _ = self.rb.readAssumeLength();
                    }
                }
                const pulseOutput = PulseTable[self.pulse1.output() + self.pulse2.output()];
                const tndOutput = TndTable[3 * self.triangle.output() + 2 * self.noise.output() + self.dmc.output()];
                const s: f32 = (pulseOutput + tndOutput);
                // const s:f32 = @as(f32, @floatFromInt(self.dmc.output())) / 127.0;

                // const s:f32 = @as(f32, @floatFromInt(self.pulse1.output())) / 15.0 +
                //               (@as(f32, @floatFromInt(self.pulse2.output())) / 15.0) +
                //                (@as(f32, @floatFromInt(self.triangle.output())) / 15.0);
                // pPulse.cycles +%= numCyclesInFrame;
                // const s = waveform_square_f32(pPulse.time, pPulse.dutyCycle, pPulse.amplitude);
                // pPulse.time += pPulse.advance;

                // pPulse.cycles -= pPulse.sweepPeriod;
                // const t1 = pPulse.timer >> pPulse.sweepSetup.shiftCount;
                // const neg, const overflow = @subWithOverflow(pPulse.timer,t1);
                // const neg1 = (~overflow)*neg;
                // const new_timer =  if (pPulse.sweepSetup.negative) neg1 else pPulse.timer+%t1;
                // pPulse.setTimer(@truncate(new_timer));
                // const b: u1 = getBit(pPulse.shiftRegister, 0);
                // const s: f32 = if (b == 0) pPulse.amplitude else 0.0;

                pFramesOutF32[i * 2] = s;
                pFramesOutF32[i * 2 + 1] = s;
                // pFramesOutF32[i * 2] = s;
                // pFramesOutF32[i * 2 + 1] = s;
            }
        } else {
            // pPulse.time += @as(f64, @floatFromInt(frame_count)) * pPulse.advance;

            // pPulse.cycles +%= frame_count * numCyclesInFrame;
            // while (pPulse.cycles > pPulse.noisePeriod) {
            //     pPulse.cycles -= pPulse.noisePeriod;
            //     pPulse.shift();
            // }
        }
        frames_read.* = frame_count;
        return .success;
    }
    pub fn onSeek(
        ds: *zaudio.DataSource,
        frame_index: u64,
    ) callconv(.c) zaudio.Result {
        _ = &ds;
        _ = &frame_index;
        return .success;
    }
    pub fn onGetDataFormat(
        ds: *zaudio.DataSource,
        format: ?*zaudio.Format,
        channels: ?*u32,
        sample_rate: ?*u32,
        channel_map: ?[*]zaudio.Channel,
        channel_map_cap: usize,
    ) callconv(.c) zaudio.Result {
        _ = &ds;
        format.?.* = .float32;
        channels.?.* = 2;
        sample_rate.?.* = DEVICE_SAMPLE_RATE;

        ma_channel_map_init_standard(.ma_standard_channel_map_microsoft, channel_map, channel_map_cap, 2);

        return .success;
    }
};

const Apu = @This();
const Control = packed struct {
    lcPulse1: bool = false,
    lcPulse2: bool = false,
    lcTriangle: bool = false,
    lcNoise: bool = false,
    dmcEnable: bool = false,
    _: u3 = 0,
};
const Status = packed struct {
    lcPulse1: bool = false,
    lcPulse2: bool = false,
    lcTriangle: bool = false,
    lcNoise: bool = false,
    dmcEnable: bool = false,
    _: u1 = 0,
    frameInterrupt: bool = false,
    dmcInterrupt: bool = false,
};

const Command = struct {
    cycle: u64,
    address: u16,
    data: u8,
};

const DEVICE_CHANNELS = 2;
const DEVICE_SAMPLE_RATE = 48000;

const AudioState = struct {
    device: *zaudio.Device,
    engine: *zaudio.Engine,
    hpf: *zaudio.HpfNode,
    lpf: *zaudio.LpfNode,

    fn data_callback(device: *zaudio.Device, pOutput: ?*anyopaque, _: ?*const anyopaque, frame_count: u32) callconv(.c) void {
        const audio: ?*AudioState = @ptrCast(@alignCast(device.getUserData()));

        if (audio) |a| {
            a.engine.asNodeGraphMut().readPcmFrames(pOutput.?, frame_count, null) catch {
                std.debug.print(">>???\n", .{});
            };
        }
    }

    fn create(allocator: std.mem.Allocator) !*AudioState {
        const audio = try allocator.create(AudioState);

        const device = device: {
            var config = zaudio.Device.Config.init(.playback);
            config.data_callback = data_callback;
            config.user_data = audio;
            config.sample_rate = 48_000;
            config.period_size_in_frames = 480;
            config.period_size_in_milliseconds = 10;
            config.playback.format = .float32;
            config.playback.channels = 2;
            break :device try zaudio.Device.create(null, config);
        };

        const engine = engine: {
            var config = zaudio.Engine.Config.init();
            config.device = device;
            config.no_auto_start = .true32;
            break :engine try zaudio.Engine.create(config);
        };

        // first A first-order high-pass filter at 90 Hz
        const hpf_config = zaudio.HpfNode.Config.init(
            engine.asNodeGraph().getChannels(),
            engine.getSampleRate(),
            90,
            1,
        );
        const hpfNode = try engine.asNodeGraphMut().createHpfNode(hpf_config);
        // engine.asNodeGraphMut().createDataSourceNode(config: Config)

        const lpf_config = zaudio.LpfNode.Config.init(
            engine.asNodeGraph().getChannels(),
            engine.getSampleRate(),
            14000,
            1,
        );
        const lpfNode = try engine.asNodeGraphMut().createLpfNode(lpf_config);

        const endpoint = engine.asNodeGraphMut().getEndpointMut();
        try lpfNode.asNodeMut().attachOutputBus(0, endpoint, 0);
        try hpfNode.asNodeMut().attachOutputBus(0, lpfNode.asNodeMut(), 0);
        // try mixer.attachOutputBus(0, hpfNode.asNodeMut(), 0);

        audio.* = .{
            .device = device,
            .engine = engine,
            .hpf = hpfNode,
            .lpf = lpfNode,
            // .mixer = mixer,
        };
        return audio;
    }
    fn destroy(audio: *AudioState, allocator: std.mem.Allocator) void {
        audio.engine.destroy();
        audio.device.destroy();
        audio.hpf.destroy();
        audio.lpf.destroy();
        allocator.destroy(audio);
    }
};

audio: *AudioState = undefined,
memoryController: *MemoryController = undefined,
control: Control = .{},
rb: *RingBuffer = undefined,
cycle: u64 = 0,
nesDS: *NesDS = undefined,
nesNode: *zaudio.DataSourceNode = undefined,
pub fn init(gpa: std.mem.Allocator) !Apu {
    var apu: Apu = .{};

    apu.audio = try AudioState.create(gpa); // TODO: no longer necessery?
    apu.rb = try RingBuffer.create(gpa, 4096);
    apu.nesDS = try NesDS.create(gpa, apu.rb);
    const dsNodeConfig = zaudio.DataSourceNode.Config.init(apu.nesDS.asDataSourceMut());
    apu.nesNode = (try apu.audio.engine.asNodeGraphMut().createDataSourceNode(dsNodeConfig));

    try apu.nesNode.asNodeMut().attachOutputBus(0, apu.audio.hpf.asNodeMut(), 0);
    try apu.audio.engine.start();

    return apu;
}

pub fn deinit(self: *Apu, gpa: std.mem.Allocator) void {
    self.audio.device.stop() catch {
        std.debug.print("can't stop device\n", .{});
    };
    self.audio.engine.stop() catch {
        std.debug.print("can't stop the engine\n", .{});
    };
    self.audio.destroy(gpa);
    self.nesNode.destroy();
    self.nesDS.destroy(gpa);

    self.rb.deinit(gpa);
}
pub fn setMemoryController(self: *Apu, mc: *MemoryController) void {
    self.nesDS.setMemoryController(mc);
}
// It ticks approximately 4 times per frame (240Hz NTSC), and executes either a 4 or 5-step sequence,
// depending how it is configured. It may optionally issue an IRQ on the last tick of the 4-step sequence.
// https://www.nesdev.org/wiki/APU_Frame_Counter
// The sequencer is clocked on every other CPU cycle, so 2 CPU cycles = 1 APU cycle.
pub fn run(self: *Apu, cycle: u64) void {
    self.cycle = cycle;
}

pub fn endFrame(self: *Apu) void {
    self.cycle = 0;
    self.rb.write(.{
        .address = 0xFFFF,
        .data = 0,
        .cycle = 32000,
    }) catch |e| {
        std.debug.panic("can't write to ringbuffer {any}", .{e});
    };
}

pub fn read(self: *Apu, addr: u16) u8 {
    // std.debug.print("apu read: 0x{X}\n", .{addr});
    switch (addr) {
        0x4015 => {
            const status: Status = .{
                .lcPulse1 = self.control.lcPulse1,
                .lcPulse2 = self.control.lcPulse2,
                .lcTriangle = self.control.lcTriangle,
                .dmcEnable = self.control.dmcEnable,
                .frameInterrupt = false,
            };
            return @bitCast(status);
        },
        else => return 0, // FIXME: open bus
    }
}

pub fn write(self: *Apu, addr: u16, data: u8) void {
    self.rb.write(.{ .address = addr, .data = data, .cycle = self.cycle }) catch |e| {
        std.debug.panic("can't write to ringbuffer {any}", .{e});
    }; // FIXME: control command handled here

    // (switch (addr) {
    //     0x4000 => self.pulse1Channel.setDutyAndVolume(@bitCast(data)),
    //     0x4001 => self.pulse1Channel.setSweep(@bitCast(data)),
    //     0x4002 => self.pulse1Channel.setTimerLow(data),
    //     0x4003 => self.pulse1Channel.setTimerHigh(@bitCast(data)),
    //
    //     0x4004 => self.pulse2Channel.setDutyAndVolume(@bitCast(data)),
    //     0x4005 => self.pulse2Channel.setSweep(@bitCast(data)),
    //     0x4006 => self.pulse2Channel.setTimerLow(data),
    //     0x4007 => self.pulse2Channel.setTimerHigh(@bitCast(data)),
    //
    //     0x4008 => self.triangleChannel.setLinearCounter(@bitCast(data)),
    //     0x4009 => {},
    //     0x400A => self.triangleChannel.setTimerLow(data),
    //     0x400B => self.triangleChannel.setTimerHigh(@bitCast(data)),

    // 0x400C => self.noiseChannel.setVolume(@bitCast(data)),
    // 0x400D => {},
    // 0x400E => self.noiseChannel.setNoise(@bitCast(data)),
    // 0x400F => self.noiseChannel.setLengthCounter(@bitCast(data)),
    //
    // 0x4010 => self.dmcChannel.frequency = @bitCast(data),
    // 0x4011 => self.dmcChannel.directLoad = @bitCast(data),
    // 0x4012 => self.dmcChannel.sampleAddress = data,
    // 0x4013 => self.dmcChannel.sampleLength = data,
    // 0x4015 => {
    //     const control: Control = @bitCast(data);
    //     self.pulse1Channel.enable(control.lcPulse1) catch {
    //         std.debug.print("can't enable pulse1\n", .{});
    //     };
    //     self.pulse2Channel.enable(control.lcPulse2) catch {
    //         std.debug.print("can't enable pulse2\n", .{});
    //     };
    //     self.triangleChannel.enable(control.lcTriangle) catch {
    //         std.debug.print("can't enable pulse2\n", .{});
    //     };
    // self.noiseChannel.enable(control.lcNoise) catch {
    //             std.debug.print("can't enable pulse2\n", .{});
    //         };
    //         self.dmcChannel.enable(control.dmcEnable, self.memoryController) catch {
    //             std.debug.print("can't enable pulse2\n", .{});
    //         };
    //         // self.status.lcTriangle = self.control.lcTriangle;
    //         // self.status.lcNoise = self.control.lcNoise;
    //         // self.status.dmcEnable = self.control.dmcEnable;
    //         // std.debug.print("{any}\n", .{self.control});
    //     },
    //     0x4017 => {
    //         self.frameCounter = @bitCast(data);
    //         // std.debug.print("frame counter: {any}\n", .{self.frameCounter});
    //     },
    //     // else => {}, // ignore for now
    //     else => std.debug.panic("wrong address for APU 0x{x}", .{addr}),
    // }) catch {
    //     std.debug.print("something went wrong", .{});
    // };
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
