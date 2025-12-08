const std = @import("std");

const Apu = @This();
const zaudio = @import("zaudio");

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
audio: *AudioState = undefined,
pulse1Config: zaudio.Waveform.Config = undefined,
pulse1Wave: *zaudio.Waveform = undefined,
pulse1Node: *zaudio.DataSourceNode = undefined,

const DEVICE_FORMAT = zaudio.Format.float32;
const DEVICE_CHANNELS = 2;
const DEVICE_SAMPLE_RATE = 48000;

const AudioState = struct {
    device: *zaudio.Device,
    engine: *zaudio.Engine,

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

        audio.* = .{
            .device = device,
            .engine = engine,
        };
        return audio;
    }
    fn destroy(audio: *AudioState, allocator: std.mem.Allocator) void {
        audio.engine.destroy();
        audio.device.destroy();
        allocator.destroy(audio);
    }
};
pub fn init(gpa: std.mem.Allocator) !Apu {
    var apu: Apu = .{};

    apu.audio = try AudioState.create(gpa);

    try apu.audio.engine.start();

    // const music = try apu.audio.engine.createSoundFromFile(
    //     "content/" ++ "Broke For Free - Night Owl.mp3",
    //     .{ .flags = .{ .stream = true } },
    // );
    // // defer music.destroy();
    // music.setVolume(1.5);
    // try music.start();

    apu.pulse1Config = zaudio.Waveform.Config.init(.float32, apu.audio.engine.asNodeGraph().getChannels(), apu.audio.engine.getSampleRate(), zaudio.Waveform.Type.square, 0.5, 440);
    apu.pulse1Wave = try zaudio.Waveform.create(apu.pulse1Config);

    apu.pulse1Node = try apu.audio.engine.asNodeGraphMut().createDataSourceNode(
        zaudio.DataSourceNode.Config.init(apu.pulse1Wave.asDataSourceMut()),
    );
    const node = apu.audio.engine.asNodeGraphMut().getEndpointMut();
    try apu.pulse1Node.asNodeMut().attachOutputBus(0, node, 0);
    //
    try apu.pulse1Node.asNodeMut().setState(.stopped);
    // // try waveform_node.asNodeMut().setState(.started);
    //
    // var threaded: std.Io.Threaded = .init_single_threaded;
    //         std.Io.sleep(threaded.io(), std.Io.Duration.fromSeconds(10), std.Io.Clock.real) catch {
    //             std.debug.print("can't sleep", .{});
    //         };

    return apu;
}

pub fn deinit(self: *Apu, gpa: std.mem.Allocator) void {
    self.pulse1Node.destroy();
    self.pulse1Wave.destroy();
    self.audio.destroy(gpa);
}

// once per frame..
pub fn clock(self: *Apu) void {
    _ = &self;
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
        0x4000...0x4003 => {
            @as([*]u8, @ptrCast(&self.pulse1Channel))[addr - 0x4000] = data;
            // std.debug.print("{any}\n", .{self.pulse1Channel});
        },
        0x4004...0x4007 => {
            @as([*]u8, @ptrCast(&self.pulse2Channel))[addr - 0x4004] = data;
            // std.debug.print("{any}\n", .{self.pulse2Channel});
        },
        0x4008...0x400B => {
            @as([*]u8, @ptrCast(&self.triangleChannel))[addr - 0x4008] = data;
            // std.debug.print("0x{x}\n", .{data});
        },
        0x400C...0x400F => @as([*]u8, @ptrCast(&self.noiseChannel))[addr - 0x400C] = data,
        0x4010...0x4013 => {
            @as([*]u8, @ptrCast(&self.dmcChannel))[addr - 0x4010] = data;
            // std.debug.print("dmc channel: {any}\n", .{self.dmcChannel});
        },
        0x4015 => {
            self.control = @bitCast(data);
            self.status.lcPulse1 = self.control.lcPulse1;
            self.status.lcPulse2 = self.control.lcPulse2;
            self.status.lcTriangle = self.control.lcTriangle;
            self.status.lcNoise = self.control.lcNoise;
            self.status.dmcEnable = self.control.dmcEnable;
            // std.debug.print("{any}\n", .{self.control});
        },
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
