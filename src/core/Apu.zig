const std = @import("std");

const zaudio = @import("zaudio");
const DEVICE_FORMAT = zaudio.Format.float32;
const MemoryController = @import("MemoryController.zig");

const Apu = @This();
const fCPU: f64 = 1.789773*1000_000.0; // NTSC
const LengthTable: [32]u8 = .{ 
     // |  0   1   2   3   4   5   6   7    8   9   A   B   C   D   E   F
     // +----------------------------------------------------------------
           10,254, 20,  2, 40,  4, 80,  6, 160,  8, 60, 10, 14, 12, 26, 14, // 00-0F  
           12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30  // 10-1F  
};
const RateInCpuCycles = [_]f64{428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106,  84,  72,  54};
const LengthTimer = struct {
};

// how many cpu cycles before shift register clocks
const NoisePeriod = [_]f64{4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068};

const NoiseDS = struct {
    ds: zaudio.DataSourceBase = undefined,
    noisePeriod: u32 = 0, // num cpu cycles until next shift 
    loopNoise: bool = false,
    // time: f64 = 0,
    // advance: f64 = 0,
    shiftRegister: u15 = 1,
    amplitude: f32 = 1.0,
    cycles: u64 = 0,

    pub fn shift(noise: *NoiseDS) void {
        // const res = getBit(noise.shiftRegister,0);
        const feedback = if (noise.loopNoise) 
                             getBit(noise.shiftRegister, 0)^getBit(noise.shiftRegister,6)
                         else 
                             getBit(noise.shiftRegister, 0)^getBit(noise.shiftRegister,1);
        noise.shiftRegister >>= 1;                      
        noise.shiftRegister = setBit(noise.shiftRegister,14, feedback);
        // return res;
    }

    pub fn calculateAdvance(period: u64) f64 {
        const freq = fCPU / @as(f64, @floatFromInt(period));
        return (1.0 / (DEVICE_SAMPLE_RATE / freq));
    }
    const numCyclesInFrame: u32 = @intFromFloat(fCPU / DEVICE_SAMPLE_RATE );

    pub fn create(allocator: std.mem.Allocator, period: u4, loop:bool, a: f32) zaudio.Error!*NoiseDS {
        var noise = try allocator.create(NoiseDS);
        noise.noisePeriod = NoisePeriod[period];
        noise.loopNoise = loop;
        noise.cycles = 0;
        // noise.time = 0.0;
        // noise.advance = calculateAdvance(period);
        noise.shiftRegister = 1;
        noise.amplitude = a;
        const dsConfig = zaudio.DataSource.Config.init();
        dsConfig.vtable = vtable;
        try zaudio.DataSource.create(dsConfig, &noise.ds);
    }

    pub fn destroy(handle: *NoiseDS, allocator: std.mem.Allocator) void {
        zaudio.DataSource.destroy(handle.ds);
        allocator.destroy(handle);
    }
    
    pub fn asDataSource(handle: *NoiseDS) *const zaudio.DataSource {
        return @as(*const zaudio.DataSource, @ptrCast(handle));
    }
    pub fn asDataSourceMut(handle: *NoiseDS) *zaudio.DataSource {
        return @as(*zaudio.DataSource, @ptrCast(handle));
    }

    const vtable: zaudio.DataSource.VTable = .{
        .onRead = onRead,
        .onSeek = onSeek, // noop
        .onGetDataFormat = onGetDataFormat, 
        .onGetCursor = null,
        .onGetLength = null,
        .onSetLooping = null,
        .flags = 0,
    };

    pub fn onRead(ds: *zaudio.DataSource,
                  frames_out: ?*anyopaque,
                  frame_count: u64,
                  frames_read: *u64) callconv(.c) zaudio.Result {
        const pNoise:*NoiseDS = @ptrCast(@alignCast(ds));
        if (frames_out) |*frames| {
            var pFramesOutF32: *f32 = @ptrCast(frames);
            for (0..frame_count) |i| {
                pNoise.cycles += numCyclesInFrame;
                if (pNoise.cycles > pNoise.noisePeriod) {
                    pNoise.cycles -= pNoise.noisePeriod;
                    pNoise.shift();
                }
                const b:u1 = getBit(pNoise.shiftRegister,0);
                const s:f32 = pNoise.amplitude * b;
                
                pFramesOutF32[i*2] = s;
                pFramesOutF32[i*2+1] = s;
            }



        } else {
            for (0..frame_count) |_| {
                pNoise.cycles += numCyclesInFrame;
                if (pNoise.cycles > pNoise.noisePeriod) {
                    pNoise.cycles -= pNoise.noisePeriod;
                    pNoise.shift();
                }
            }
            // TODO: advance here
            // for 

            // pNoise.time += pNoise.advance * frame_count;
        }
        frames_read.* = frame_count;
        return .success;
    }
    pub fn onSeek(ds: *zaudio.DataSource,
                  frame_index: u64,
                  ) callconv(.c) zaudio.Result {
        _ = &ds; _ = &frame_index;
        return .success;
    }
    pub fn onGetDataFormat(ds: *zaudio.DataSource,
            format: ?*zaudio.Format,
            channels: ?*u32,
            sample_rate: ?*u32,
            channel_map: ?[*]zaudio.Channel,
            channel_map_cap: usize,
            ) callconv(.c) zaudio.Result {
        _ = &ds;
        _ = &format;
        _ = &channels;
        _ = &sample_rate;
        _ = &channel_map;
        _ = &channel_map_cap;
        // const pNoise:*NoiseDS = @ptrCast(@alignCast(ds));
        format.?.* = .float32;
        channels.?.* = 2;
        sample_rate.?.* = 0; // no notion for noise


    ma_channel_map_init_standard(
        .ma_standard_channel_map_default, 
        channel_map, channel_map_cap, 2);

        return .success;
    }
    extern fn ma_channel_map_init_standard(
              channel_map: standard_channel_map,
              channel: *zaudio.Channel,
              cap: usize,
              channels: u32
            ) void;

    pub const standard_channel_map = enum (u32) {
    ma_standard_channel_map_microsoft,
    ma_standard_channel_map_alsa,
    ma_standard_channel_map_rfc3551,   // Based off AIFF. */
    ma_standard_channel_map_flac,
    ma_standard_channel_map_vorbis,
    ma_standard_channel_map_sound4,    // FreeBSD's sound(4). */
    ma_standard_channel_map_sndio,     // www.sndio.org/tips.html */
    ma_standard_channel_map_webaudio = .ma_standard_channel_map_flac,
    ma_standard_channel_map_default = .ma_standard_channel_map_microsoft


    };
};


const PulseChannel = struct {
    const DutyCycleAndVolume = packed struct { 
        volume: u4 = 0, // envelope period
        constantVolume: bool = false,
        lengthCounterHalt: bool = false, // loop envelope
        duty: u2 = 0,
    };
    const SweepSetup = packed struct {
        shiftCount: u3 = 0,
        negative: bool = false,
        period: u3 = 0,
        enabled: bool = false,
    };
    const TimerAndLengthCounter = packed struct {
        timerHigh: u3 = 0,
        lengthCounterLoad: u5 = 0,
    };
    dutyCycleAndVolume: DutyCycleAndVolume = .{},
    sweepSetup: SweepSetup = .{},
    timerLow: u8 = 0,
    timerAndLengthCounter: TimerAndLengthCounter = .{},
    config: zaudio.Pulsewave.Config = undefined,
    wave: *zaudio.Pulsewave = undefined,
    node: *zaudio.DataSourceNode = undefined,
    engine: *zaudio.Engine = undefined,
    sound: *zaudio.Sound = undefined,
    enabled: bool = false,
    muted: bool = false,
    length: u8 = 0,
    sweepPeriod: u3 = 0,
    rawTimerPeriod: u11 = 0,
    volumeCounter: u8 = 0,
    envelopeVolume: u8 = 0,

    pub fn create(audio: *AudioState) !PulseChannel {
        var channel: PulseChannel = .{};
        channel.config = zaudio.Pulsewave.Config.init(.float32, audio.engine.asNodeGraph().getChannels(), audio.engine.getSampleRate(), 0.8, 0.0, 440);
        channel.wave = try zaudio.Pulsewave.create(channel.config);
        channel.engine = audio.engine;

        // var soundConfig = zaudio.Sound.Config.init();
        // soundConfig.data_source = channel.wave.asDataSourceMut();
        channel.sound = try audio.engine.createSoundFromDataSource(
                channel.wave.asDataSourceMut(), .{}, null);

        channel.node = try audio.engine.asNodeGraphMut().createDataSourceNode(
            zaudio.DataSourceNode.Config.init(channel.wave.asDataSourceMut()),
        );
        try channel.sound.asNodeMut().attachOutputBus(0,audio.hpf.asNodeMut(), 0);


        // try channel.node.asNodeMut().attachOutputBus(0, node, 0);
        //
        try channel.node.asNodeMut().setState(.stopped);
        return channel;
    }
    pub fn destroy(self: *PulseChannel) void {
       self.wave.destroy(); 
       self.node.destroy();
       self.sound.destroy();
    }
    pub fn enable(self: *PulseChannel, on: bool) !void {
        if (on == self.enabled) {
          return;
        } else {
            if (on) {
                self.enabled = true;
                try self.sound.start();
                // try self.node.asNodeMut().setState(.started);
            } else {
                self.enabled = false;
                try self.sound.stop();
                // try self.node.asNodeMut().setState(.stopped);
                self.length = 0;
            }
        }
    }
    pub fn setDutyAndVolume(self: *PulseChannel, d: DutyCycleAndVolume) void {
        self.dutyCycleAndVolume = d;
        self.volumeCounter = d.volume;
        self.envelopeVolume = 15;
        var amplitude = @as(f64, @floatFromInt(d.volume)) / 16.0;
        if (!self.dutyCycleAndVolume.constantVolume) {
            amplitude = 1.0;
        }
        if (d.duty == 3) {
            amplitude = -amplitude;
        }
        const duty: f64 = switch (d.duty) {
            0 => 0.125,
            1 => 0.25,
            2 => 0.5,
            3 => 0.25
        };
        self.wave.setAmplitude(amplitude) catch { std.debug.print("can't set ampl\n", .{});};
        self.wave.setDutyCycle(duty) catch { std.debug.print("can't set ampl\n", .{});};
        if (!self.dutyCycleAndVolume.constantVolume) {
            // self.wave.setAmplitude(1.0) catch { std.debug.print("can't set ampl\n", .{});};
            self.sound.setFadeInMilliseconds(-1.0, 0.0, 8*(@as(u64,self.dutyCycleAndVolume.volume) + 1));
        }
    }
    pub fn setTimerLow(self: *PulseChannel, _timerLow: u8) void {
        self.timerLow = _timerLow;
        const t:u11 = _timerLow + (@as(u11,self.timerAndLengthCounter.timerHigh) << 8);
        self.rawTimerPeriod = t;
        // FIXME: if t < 8 mute
        const frequency =  fCPU / (16.0 * (@as(f64, @floatFromInt(t)) + 1.0));
        self.wave.setFrequency(frequency) catch { std.debug.print("can't set freq\n", .{});};
    }
    // Writing to $4003/$4007 reloads the length counter, restarts the envelope, and resets the phase of the pulse generator.
    pub fn setTimerHigh(self: *PulseChannel, _timerHigh: TimerAndLengthCounter) void {
        self.timerAndLengthCounter = _timerHigh;
        const t:u11 = self.timerLow + (@as(u11,self.timerAndLengthCounter.timerHigh) << 8);
        // FIXME: if t < 8 mute
        const frequency =  fCPU / (16.0 * (@as(f64, @floatFromInt(t)) + 1.0));
        self.wave.setFrequency(frequency) catch { std.debug.print("can't set freq\n", .{});};
        // self.node.asNodeMut().setState(.started) catch { std.debug.print("can't set freq\n", .{});};
        self.sound.start() catch { std.debug.print("can't set freq\n", .{});};
        if (_timerHigh.lengthCounterLoad == 0) {
            // one shot
            //  the length counter should be loaded with a time longer than the length of the envelope
            //  to prevent it from being cut off early.
            // self.length = 8; //FIXME: probably wrong
           const endTime = self.engine.asNodeGraph().getTime() +
                        (@as(u64, self.volumeCounter) * 16 *
                        self.engine.getSampleRate() / 1000);
            self.sound.setStopTimeInPcmFrames(endTime);
            self.sound.setLooping(false);
           // self.node.asNodeMut().setStateTime(.stopped, endTime) catch { std.debug.print("can't set freq\n", .{});};
        } else if (_timerHigh.lengthCounterLoad == 1) {
            // FIXME: infinite play
            // self.dutyCycleAndVolume.lengthCounterHalt = true;
            self.sound.setLooping(true);
        } else {
           const endTime = self.engine.asNodeGraph().getTime() +
                        (@as(u64, LengthTable[_timerHigh.lengthCounterLoad]) * 16 *
                        self.engine.getSampleRate() / 1000);
           // self.node.asNodeMut().setStateTime(.stopped, endTime) catch { std.debug.print("can't set freq\n", .{});};
           self.sound.setStopTimeInPcmFrames(endTime);
           self.sound.setLooping(false);
        }
    }
    // pub fn clockLength(self: *PulseChannel) void {
    //     if (!self.dutyCycleAndVolume.lengthCounterHalt and self.length > 0) {
    //         self.length -= 1;
    //     }
    //     if (self.length == 0) {
    //         self.wave.setAmplitude(0) catch { std.debug.print("can't setAmplitude\n", .{});};
    //     }
    //     // now sweep unit... https://www.nesdev.org/wiki/APU_Sweep
    //     // TODO: different sweep algorithm for two pulses..
    //     if (self.sweepSetup.enabled and self.sweepSetup.shiftCount > 0) {
    //         if (self.sweepPeriod == 0) {
    //             self.sweepPeriod = self.sweepSetup.period;
    //             const t:u11 = self.timerLow + (@as(u11,self.timerAndLengthCounter.timerHigh) << 8);
    //             const t1 = t >> self.sweepSetup.shiftCount;
    //             self.rawTimerPeriod =  if (self.sweepSetup.negative) self.rawTimerPeriod-%t1 else self.rawTimerPeriod+%t1;
    //             // FIXME: clamp to 0.. targetPeriod
    //             // FIXME: if t < 8 mute
    //             const frequency =  fCPU / (16.0 * (@as(f64, @floatFromInt(self.rawTimerPeriod)) + 1.0));
    //             self.wave.setFrequency(frequency) catch { std.debug.print("can't set freq\n", .{});};
    //         } else {
    //             self.sweepPeriod -= 1;
    //         }
    //     }
    //
    // }
    // pub fn clockVolumeEnvelope(self: *PulseChannel) void {
    //     if (!self.dutyCycleAndVolume.constantVolume) {
    //         if (self.volumeCounter == 0) {
    //             self.volumeCounter = self.dutyCycleAndVolume.volume;
    //             if (self.envelopeVolume == 0 and self.dutyCycleAndVolume.lengthCounterHalt) {
    //                 self.envelopeVolume = 15;
    //             } else if (self.envelopeVolume > 0) {
    //                 self.envelopeVolume -= 1;
    //             }
    //             if (self.envelopeVolume > 0) {
    //                  // FIXME: negative volume on inverted period..
    //                  const amplitude = @as(f64, @floatFromInt(self.envelopeVolume)) / 16.0;
    //                  self.wave.setAmplitude(amplitude) catch { std.debug.print("can't set ampl\n", .{});};
    //             }
    //         } else {
    //             self.volumeCounter -=1;
    //         }
    //     }
    // }

    pub fn setSweep(self: *PulseChannel, sweep: SweepSetup) void {
        self.sweepSetup = sweep;
        self.sweepPeriod = sweep.period;
        // self.sound.setPitch(pitch: f32)
    }
};

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
    rawTimerPeriod: u11 = 0,
    config: zaudio.Waveform.Config = undefined,
    wave: *zaudio.Waveform = undefined,
    node: *zaudio.DataSourceNode = undefined,
    engine: *zaudio.Engine = undefined,
    enabled: bool = false,
    length: u8 = 0,
    linearTimer: u7 = 0,
    pub fn create(audio: *AudioState) !TriangleChannel {
        var channel: TriangleChannel = .{};
        channel.engine = audio.engine;
        channel.config = zaudio.Waveform.Config.init(
          .float32, audio.engine.asNodeGraph().getChannels(), audio.engine.getSampleRate(), .triangle, 0.0, 440);
        channel.wave = try zaudio.Waveform.create(channel.config);

        channel.node = try audio.engine.asNodeGraphMut().createDataSourceNode(
            zaudio.DataSourceNode.Config.init(channel.wave.asDataSourceMut()),
        );
        // const node = audio.engine.asNodeGraphMut().getEndpointMut();
        try channel.node.asNodeMut().attachOutputBus(0, audio.hpf.asNodeMut(), 0);
        //
        try channel.node.asNodeMut().setState(.stopped);
        return channel;
    }
    pub fn destroy(self: *TriangleChannel) void {
       self.wave.destroy(); 
       self.node.destroy();
    }
    pub fn enable(self: *TriangleChannel, on: bool) !void {
        if (on == self.enabled) {
          return;
        } else {
            if (on) {
                self.enabled = true;
                try self.node.asNodeMut().setState(.started);
            } else {
                self.enabled = false;
                try self.node.asNodeMut().setState(.stopped);
            }
        }
    }
    pub fn setLinearCounter(self: *TriangleChannel, _counter: LinearCounter) void {
        self.linearCounter = _counter;
        self.linearTimer = _counter.linearCounterReloadValue;
        self.node.asNodeMut().setState(.started) catch { std.debug.print("can't set freq\n", .{});};
        const endTime = self.engine.asNodeGraph().getTime() +
                        (@as(u64, self.linearCounter.linearCounterReloadValue) * 16 *
                        self.engine.getSampleRate() / 1000);
        self.node.asNodeMut().setStateTime(.stopped, endTime) catch { std.debug.print("can't set freq\n", .{});};
    }
    pub fn setTimerLow(self: *TriangleChannel, _timerLow: u8) void {
        self.timerLow = _timerLow;
        self.rawTimerPeriod = _timerLow + (@as(u11,self.timerAndLengthCounter.timerHigh) << 8);
        // FIXME: if t < 8 mute
        const frequency =  fCPU / (32.0 * (@as(f64, @floatFromInt(self.rawTimerPeriod)) + 1.0));
        self.wave.setFrequency(frequency) catch { std.debug.print("can't set freq\n", .{});};
    }
    // Writing to $4003/$4007 reloads the length counter, restarts the envelope, and resets the phase of the pulse generator.
    pub fn setTimerHigh(self: *TriangleChannel, _timerHigh: TimerAndLengthCounter) void {
        self.timerAndLengthCounter = _timerHigh;
        const t:u11 = self.timerLow + (@as(u11,self.timerAndLengthCounter.timerHigh) << 8);
        // FIXME: if t < 8 mute
        const frequency =  fCPU / (32.0 * (@as(f64, @floatFromInt(t)) + 1.0));
        self.wave.setFrequency(frequency) catch { std.debug.print("can't set freq\n", .{});};
        self.node.asNodeMut().setState(.started) catch { std.debug.print("can't set freq\n", .{});};
        if (_timerHigh.lengthCounterLoad == 0) {
            // one shot
            //  the length counter should be loaded with a time longer than the length of the envelope
            //  to prevent it from being cut off early.
            // self.length = 8; //FIXME: probably wrong
           const endTime = self.engine.asNodeGraph().getTime() +
                        (16 * 16 *
                        self.engine.getSampleRate() / 1000);
           self.node.asNodeMut().setStateTime(.stopped, endTime) catch { std.debug.print("can't set freq\n", .{});};
        } else if (_timerHigh.lengthCounterLoad == 1) {
            // FIXME: infinite play
            self.linearCounter.lengthCounterHalt = true;
        } else {
           const endTime = self.engine.asNodeGraph().getTime() +
                        (@as(u64, LengthTable[_timerHigh.lengthCounterLoad]) * 16 *
                        self.engine.getSampleRate() / 1000);
           self.node.asNodeMut().setStateTime(.stopped, endTime) catch { std.debug.print("can't set freq\n", .{});};
        }
    }
    // pub fn clockLength(self: *TriangleChannel) void {
    //     if (!self.linearCounter.lengthCounterHalt and self.length > 0) {
    //         self.length -= 1;
    //     }
    //     if (self.length == 0) {
    //         self.wave.setAmplitude(0) catch { std.debug.print("can't setAmplitude\n", .{});};
    //     }
    //
    // }
    // pub fn clockLinearCounter(self: *TriangleChannel) void {
    //     if (self.linearCounter.lengthCounterHalt) {
    //         if (self.linearTimer == 0) {
    //             self.linearTimer = self.linearCounter.linearCounterReloadValue;
    //         }
    //     } 
    //     if (self.linearTimer > 0) {
    //         self.linearTimer -= 1;
    //     }
    //     if (self.linearTimer == 0) {
    //         self.wave.setAmplitude(0) catch { std.debug.print("can't setAmplitude\n", .{});};
    //     }
    // }

};
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
    lengthCounter: LengthCounter = .{},
    config: zaudio.Noise.Config = undefined,
    wave: *zaudio.Noise = undefined,
    node: *zaudio.DataSourceNode = undefined,
    engine: *zaudio.Engine = undefined,
    enabled: bool = false,
    length: u8 = 0,
    sweepPeriod: u4 = 0,
    volumeCounter: u8 = 0,
    envelopeVolume: u8 = 0,
    linearTimer: u8 = 0,

    pub fn create(audio: *AudioState) !NoiseChannel {
        var channel: NoiseChannel = .{};
        channel.engine = audio.engine;
        channel.config = zaudio.Noise.Config.init(
                    .float32, 
                    audio.engine.asNodeGraph().getChannels(), 
                    .white,
                     0, 0.0); // TODO: seed,
        channel.wave = try zaudio.Noise.create(channel.config);

        channel.node = try audio.engine.asNodeGraphMut().createDataSourceNode(
            zaudio.DataSourceNode.Config.init(channel.wave.asDataSourceMut()),
        );
        // const node = audio.engine.asNodeGraphMut().getEndpointMut();
        try channel.node.asNodeMut().attachOutputBus(0, audio.hpf.asNodeMut(), 0);
        //
        try channel.node.asNodeMut().setState(.stopped);
        return channel;
    }
    pub fn destroy(self: *NoiseChannel) void {
       self.wave.destroy(); 
       self.node.destroy();
    }
    pub fn enable(self: *NoiseChannel, on: bool) !void {
        if (on == self.enabled) {
          return;
        } else {
            if (on) {
                self.enabled = true;
                try self.node.asNodeMut().setState(.started);
            } else {
                self.enabled = false;
                try self.node.asNodeMut().setState(.stopped);
                self.length = 0;
            }
        }
    }
    pub fn setVolume(self: *NoiseChannel, v: Volume) void {
        self.volume = v;
        self.volumeCounter = v.volume;
        self.envelopeVolume = 15;
        const amplitude = @as(f64, @floatFromInt(v.volume)) / 16.0;
        self.wave.setAmplitude(amplitude) catch { std.debug.print("can't set ampl\n", .{});};
    }
    // Writing to $4003/$4007 reloads the length counter, restarts the envelope, and resets the phase of the pulse generator.
    // pub fn clockLength(self: *NoiseChannel) void {
    //     if (!self.volume.lengthCounterHalt and self.length > 0) {
    //         self.length -= 1;
    //     }
    //     if (self.length == 0) {
    //         self.wave.setAmplitude(0) catch { std.debug.print("can't setAmplitude\n", .{});};
    //     }
    //
    // }
    // pub fn clockVolumeEnvelope(self: *NoiseChannel) void {
    //     if (!self.volume.constantVolume) {
    //         if (self.volumeCounter == 0) {
    //             self.volumeCounter = self.volume.volume;
    //             if (self.envelopeVolume == 0 and self.volume.lengthCounterHalt) {
    //                 self.envelopeVolume = 15;
    //             } else if (self.envelopeVolume > 0) {
    //                 self.envelopeVolume -= 1;
    //             }
    //             if (self.envelopeVolume > 0) {
    //                  // FIXME: negative volume on inverted period..
    //                  const amplitude = @as(f64, @floatFromInt(self.envelopeVolume)) / 16.0;
    //                  self.wave.setAmplitude(amplitude) catch { std.debug.print("can't set ampl\n", .{});};
    //             }
    //         } else {
    //             self.volumeCounter -=1;
    //         }
    //     }
    //     if (self.volume.lengthCounterHalt) {
    //         if (self.linearTimer == 0) {
    //             self.linearTimer = self.lengthCounter.lengthCounterLoad;
    //         }
    //     } 
    //     if (self.linearTimer > 0) {
    //         self.linearTimer -= 1;
    //     }
    //     if (self.linearTimer == 0) {
    //         self.wave.setAmplitude(0) catch { std.debug.print("can't setAmplitude\n", .{});};
    //     }
    // }

    pub fn setNoise(self: *NoiseChannel, n: Noise) void {
        self.noise = n;
        self.sweepPeriod = n.noisePeriod;
    }
    pub fn setLengthCounter(self: *NoiseChannel, c:LengthCounter) void {
        self.lengthCounter = c;
        self.node.asNodeMut().setState(.started) catch { std.debug.print("can't set freq\n", .{});};
        const endTime = self.engine.asNodeGraph().getTime() +
                        (@as(u64, self.lengthCounter.lengthCounterLoad) * 16 *
                        self.engine.getSampleRate() / 1000);
        self.node.asNodeMut().setStateTime(.stopped, endTime) catch { std.debug.print("can't set freq\n", .{});};
    }
};
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
    directLoad: DirectLoad = .{},
    sampleAddress: u8 = 0, // %11AAAAAA.AA000000
    sampleLength: u8 = 0, // %0000LLLL.LLLL0001
    enabled: bool = false,

    config: zaudio.AudioBuffer.Config = undefined,
    buffer: *zaudio.AudioBuffer = undefined,
    engine: *zaudio.Engine = undefined,
    sound: *zaudio.Sound = undefined,
    audio: *AudioState = undefined,
    converter: *zaudio.DataConverter = undefined,

    pub fn enable(self: *DMCChannel, on: bool, mc: *MemoryController) !void {
        if (on == self.enabled) {
          return;
        } else {
            if (on) {
                self.enabled = true;
                std.debug.print("DMC on 0x{x} 0x{x} 0x{x} 0x{x}\n", .{self.sampleAddress, self.sampleLength, self.frequency.rateIndex, self.directLoad.directLoad});

        self.buffer.destroy();
       self.buffer = try zaudio.AudioBuffer.create(self.config);
        //
                // try self.buffer.seekToPcmFrame(0);
                try self.loadAndPlaySample(mc);
        // var soundConfig = zaudio.Sound.Config.init();
        // soundConfig.data_source = channel.wave.asDataSourceMut();
        self.sound.destroy();
                // try self.buffer.seekToPcmFrame(0);
        self.sound = try self.audio.engine.createSoundFromDataSource(
                self.buffer.asDataSourceMut(), .{}, null);

        // const endpoint = self.engine.asNodeGraphMut().getEndpointMut();
        // try self.sound.asNodeMut().attachOutputBus(0,endpoint, 0);
                // self.sound.setLooping(true);
                self.sound.setVolume(1.0);
                // try self.sound.seekToPcmFrame(0);
                // try self.sound.asNodeMut().setTime(0);
                try self.sound.start();
            //    var threaded: std.Io.Threaded = .init_single_threaded;
            // std.Io.sleep(threaded.io(), std.Io.Duration.fromMilliseconds(1000), std.Io.Clock.real) catch {
            //     std.debug.print("can't sleep", .{});
            // };
                // try self.node.asNodeMut().setState(.started);
            } else {
                std.debug.print("DMC off:\n", .{});
                self.enabled = false;

                try self.sound.stop();
                // try self.node.asNodeMut().setState(.stopped);
                // self.length = 0;
            }
        }
    }
    pub fn loadAndPlaySample(self: *DMCChannel, mc: *MemoryController) !void {
        const address:u16 = 0xC000 + (@as(u16, self.sampleAddress) * 64);
        const length: u16 = @as(u16, self.sampleLength) * 16 + 1;
        std.debug.print("address: 0x{x}, length: 0x{x}\n", .{address, length});
        var sampleBuf: [4096]u8 = .{0} ** 4096;
        for (0..length) |i| {
            //  if it exceeds $FFFF, it is wrapped around to $8000.
            sampleBuf[i] = mc.read(address + @as(u16, @intCast(i)));
        }
        const sampleRate = (1789773.0 / RateInCpuCycles[self.frequency.rateIndex]) ;
        // std.debug.print("sample rate: {d}\n", .{sampleRate});
        try self.converter.setRate(@intFromFloat(sampleRate), DEVICE_SAMPLE_RATE);
        var frame_count_in: u64 = length*8;
        var frame_count_out:u64 =  try self.converter.getExpectedOutputFrameCount(length*8);
        var samples: [4096*8]u8 = .{0} ** (4096*8);
        var currLevel: u8 = 0;
        for (0..length) |i| {
            const s = sampleBuf[i];
            for (0..8) |j| {
                const b:u1 = @truncate(s >> @as(u3, @intCast(j)));
                if (b == 1) {
                    currLevel +%= 1;
                } else {
                    currLevel -%= 1;
                }
                samples[i*8+j] = currLevel;
            }
        }
        // for (0..@intFromFloat(sampleRate)) | i | {
        // }
        try self.converter.processPcmFrames(&samples, &frame_count_in, &self.audio.data, &frame_count_out);
        std.debug.print("pcm frames count in: {d}, out: {d}\n", .{frame_count_in, frame_count_out});
        // const expected = ;
        // std.debug.print("expected num output frames: {d}\n", .{expected});
    }

    pub fn create(audio: *AudioState) !DMCChannel {
        var channel: DMCChannel = .{};
        channel.config = zaudio.AudioBuffer.Config.init(
                 .float32, 
                 audio.engine.asNodeGraph().getChannels(), audio.engine.getSampleRate(), &audio.data);
        channel.buffer = try zaudio.AudioBuffer.create(channel.config);
        channel.engine = audio.engine;

        // var soundConfig = zaudio.Sound.Config.init();
        // soundConfig.data_source = channel.wave.asDataSourceMut();
        channel.sound = try audio.engine.createSoundFromDataSource(
                channel.buffer.asDataSourceMut(), .{}, null);

        // channel.node = try audio.engine.asNodeGraphMut().createDataSourceNode(
        //     zaudio.DataSourceNode.Config.init(channel.wave.asDataSourceMut()),
        // );
        const endpoint = audio.engine.asNodeGraphMut().getEndpointMut();
        try channel.sound.asNodeMut().attachOutputBus(0,endpoint, 0);
        const converterConfig = zaudio.DataConverter.Config.init(.unsigned8, .float32, 
                  1, audio.engine.asNodeGraph().getChannels(), 
                 4182, // FIXME: sample rate in 
                 audio.engine.getSampleRate());
        channel.converter = try zaudio.DataConverter.create(converterConfig);
        channel.audio = audio;


        // try channel.node.asNodeMut().attachOutputBus(0, node, 0);
        //
        // try channel.node.asNodeMut().setState(.stopped);
        return channel;
    }
    pub fn destroy(self: *DMCChannel) void {
       // self.wave.destroy(); 
       self.buffer.destroy();
        self.converter.destroy();
       // self.node.destroy();
       self.sound.destroy();
    }
};

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

const FrameCounter = packed struct {
    _: u6 = 0,
    disableFrameInterrupt: bool = false,
    fiveFrameSequence: bool = false
};

pulse1Channel: PulseChannel = .{},
pulse2Channel: PulseChannel = .{},
triangleChannel: TriangleChannel = .{},
noiseChannel: NoiseChannel = .{},
dmcChannel: DMCChannel = .{},
frameCounter: FrameCounter = .{},
audio: *AudioState = undefined,
cyclesElapsed: u64 = 0,
frameInterrupt: bool = false,
memoryController: *MemoryController = undefined,

const DEVICE_CHANNELS = 2;
const DEVICE_SAMPLE_RATE = 48000;

const AudioState = struct {
    device: *zaudio.Device,
    engine: *zaudio.Engine,
    hpf: *zaudio.HpfNode,
    lpf: *zaudio.LpfNode,
    data: [DEVICE_SAMPLE_RATE*DEVICE_CHANNELS*10]f32 = .{0.0}**(DEVICE_SAMPLE_RATE*DEVICE_CHANNELS*10),

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

        audio.* = .{
            .device = device,
            .engine = engine,
            .hpf = hpfNode,
            .lpf = lpfNode,
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
pub fn init(gpa: std.mem.Allocator) !Apu {
    var apu: Apu = .{};

    apu.audio = try AudioState.create(gpa);

    try apu.audio.engine.start();
    apu.pulse1Channel = try PulseChannel.create(apu.audio);
    apu.pulse2Channel = try PulseChannel.create(apu.audio);
    apu.triangleChannel = try TriangleChannel.create(apu.audio);
    apu.noiseChannel = try NoiseChannel.create(apu.audio);
    apu.dmcChannel = try DMCChannel.create(apu.audio);

    // const music = try apu.audio.engine.createSoundFromFile(
    //     "content/" ++ "Broke For Free - Night Owl.mp3",
    //     .{ .flags = .{ .stream = true } },
    // );
    // // defer music.destroy();
    // music.setVolume(1.5);
    // try music.start();

    // try apu.pulse1Channel.node.asNodeMut().setState(.started);
    //
    // var threaded: std.Io.Threaded = .init_single_threaded;
            // std.Io.sleep(threaded.io(), std.Io.Duration.fromSeconds(10), std.Io.Clock.real) catch {
                // std.debug.print("can't sleep", .{});
            // };

    return apu;
}

pub fn deinit(self: *Apu, gpa: std.mem.Allocator) void {
    self.pulse1Channel.destroy();
    self.pulse2Channel.destroy();
    self.triangleChannel.destroy();
    self.noiseChannel.destroy();
    self.dmcChannel.destroy();
    self.audio.destroy(gpa);
}
// It ticks approximately 4 times per frame (240Hz NTSC), and executes either a 4 or 5-step sequence,
// depending how it is configured. It may optionally issue an IRQ on the last tick of the 4-step sequence.
// https://www.nesdev.org/wiki/APU_Frame_Counter
// The sequencer is clocked on every other CPU cycle, so 2 CPU cycles = 1 APU cycle.
pub fn clock(self: *Apu, apu_cycles: u64) void {
    _ = &apu_cycles;
    // for (0..4) |_| {
    // }
    // self.clockLengthCounters();
    // self.clockLengthCounters();
    if (!self.frameCounter.disableFrameInterrupt) {
        // self.frameInterrupt = true; // FIXME: trigger interupt
    }
}

pub fn read(self: *Apu, addr: u16) u8 {
    // std.debug.print("apu read: 0x{X}\n", .{addr});
    switch (addr) {
        0x4015 => {
            const status: Status = .{
                .lcPulse1 = self.pulse1Channel.enabled,
                .lcPulse2 = self.pulse2Channel.enabled,
                .lcTriangle = self.triangleChannel.enabled,
                .dmcEnable = self.dmcChannel.enabled,
                .frameInterrupt = self.frameInterrupt,
            };
            return @bitCast(status);
        },
        else => return 0, // FIXME: open bus
    }
}

pub fn write(self: *Apu, addr: u16, data: u8) void {
    // std.debug.print("apu write: 0x{X}\n", .{addr});
    switch (addr) {
        0x4000 => self.pulse1Channel.setDutyAndVolume(@bitCast(data)),
        0x4001 => self.pulse1Channel.setSweep(@bitCast(data)),
        0x4002 => self.pulse1Channel.setTimerLow(data),
        0x4003 => self.pulse1Channel.setTimerHigh(@bitCast(data)),

        0x4004 => self.pulse2Channel.setDutyAndVolume(@bitCast(data)),
        0x4005 => self.pulse2Channel.setSweep(@bitCast(data)),
        0x4006 => self.pulse2Channel.setTimerLow(data),
        0x4007 => self.pulse2Channel.setTimerHigh(@bitCast(data)),

        0x4008 => self.triangleChannel.setLinearCounter(@bitCast(data)), 
        0x4009 => {},
        0x400A => self.triangleChannel.setTimerLow(data),
        0x400B => self.triangleChannel.setTimerHigh(@bitCast(data)),

        0x400C => self.noiseChannel.setVolume(@bitCast(data)),
        0x400D => {},
        0x400E => self.noiseChannel.setNoise(@bitCast(data)),
        0x400F => self.noiseChannel.setLengthCounter(@bitCast(data)),

        0x4010 => self.dmcChannel.frequency = @bitCast(data),
        0x4011 => self.dmcChannel.directLoad = @bitCast(data),
        0x4012 => self.dmcChannel.sampleAddress = data,
        0x4013 => self.dmcChannel.sampleLength = data,
        0x4015 => {
            const control: Control = @bitCast(data);
            self.pulse1Channel.enable(control.lcPulse1) catch {
                std.debug.print("can't enable pulse1\n", .{});
            };
            self.pulse2Channel.enable(control.lcPulse2) catch {
                std.debug.print("can't enable pulse2\n", .{});
            };
            self.triangleChannel.enable(control.lcTriangle) catch {
                std.debug.print("can't enable pulse2\n", .{});
            };
            self.noiseChannel.enable(control.lcNoise) catch {
                std.debug.print("can't enable pulse2\n", .{});
            };
            self.dmcChannel.enable(control.dmcEnable, self.memoryController) catch {
                std.debug.print("can't enable pulse2\n", .{});
            };
            // self.status.lcTriangle = self.control.lcTriangle;
            // self.status.lcNoise = self.control.lcNoise;
            // self.status.dmcEnable = self.control.dmcEnable;
            // std.debug.print("{any}\n", .{self.control});
        },
        0x4017 => {
            self.frameCounter = @bitCast(data);
            // std.debug.print("frame counter: {any}\n", .{self.frameCounter});
        },
        // else => {}, // ignore for now
        else => std.debug.panic("wrong address for APU 0x{x}", .{addr}),
    }
}
//2 CPU cycles = 1 APU cycle.

// pub fn debug_print(self: *Apu) void {
//     std.debug.print("{any}\n{any}\n{any}\n{any}\n{any}\n{any}\n{any}", .{self.pulse1Channel, self.pulse2Channel,
//       self.triangleChannel, self.noiseChannel, self.dmcChannel,
//       self.status, self.frameCounter});
// }

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
