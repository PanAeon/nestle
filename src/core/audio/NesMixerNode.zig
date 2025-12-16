const std = @import("std");
const zaudio = @import("zaudio");
const NesMixerNode = @This();

pub fn pulseOut(pulse1:f32, pulse2:f32) f32 {
    if (@abs(pulse1 + pulse2) < 0.01) {
        return 0;
    } else {
        return 95.88 / (8128.0 / (pulse1 + pulse2) + 100.0);
    }
}
pub fn tndOut(triangle: f32, noise:f32, dmc:f32) f32 {
        const foo =  (triangle / 8227.0) + (noise / 12241.0) + (dmc / 22638.0);
    if (@abs(foo) < 0.01) {
        return 0.0;
    } else {
        return 159.79 / ( (1.0 / foo) + 100.0);
    }
}
//
//                                        159.79
// tnd_out = -------------------------------------------------------------
//                                     1
//            ----------------------------------------------------- + 100
//             (triangle / 8227) + (noise / 12241) + (dmc / 22638)
//
const PulseTable: [31]f32 = brk: {
    var t: [31]f32 = .{0.0}**31;
    for (1..32) |i| {
        t[i-1] = 95.52 / (8128.0 / i + 100.0);
    }
    break :brk t;
};
const TndTable: [203]f32 = brk: {
    var t: [203]f32 = .{0.0}**203;
    for (1..204) |i| {
        t[i-1] = 163.67 / (24329.0 / i + 100);
    }
    break :brk t;
};
pub fn process_pcm_frames(
            node: *zaudio.Node,
            frames_in: ?[*][*]const f32,
            frame_count_in: ?*u32,
            frames_out: *[*]f32,
            frame_count_out: *u32,
        ) callconv(.c) void {
    _ = &node;
    if (frames_in != null and frame_count_in != null) {
        const pulse0Frames = frames_in.?[0]; 
        const pulse1Frames = frames_in.?[1]; 
        const triangleFrames = frames_in.?[2]; 
        const noiseFrames = frames_in.?[3]; 
        const dmcFrames = frames_in.?[4];
        for (0..frame_count_in.?.*) |iFrame| {
            for (0..2)|i| {
                const pulse0 = 1.0 * pulse0Frames[iFrame*2+i];
                const pulse1 = 1.0 * pulse1Frames[iFrame*2+i];
                const triangle = 1.0 * triangleFrames[iFrame*2+i];
                const noise = 1.0 * noiseFrames[iFrame*2+i];
                const dmc = 1.0 * dmcFrames[iFrame*2+i];
                 const pulse_out = 0.00752 * 15.0 * (pulse0 + pulse1);
                 const tnd_out = 0.00851 * 15.0 * (triangle) + 
                       0.00494 * 15.0 * (noise) + 0.00335 * 127.0 * (dmc);
                // TODO: normalize ?
                // const pulse_out = pulseOut(pulse0Frames[iFrame*2+i], pulse1Frames[iFrame*2+i]);
                // const tnd_out = tndOut(triangleFrames[iFrame*2+i], noiseFrames[iFrame*2+i], dmcFrames[iFrame*2+i]);
    
                frames_out.*[iFrame*2+i] =  (pulse_out + tnd_out);
                   
            }
        }
       frame_count_out.* = frame_count_in.?.*;
    }
}

// pub fn getRequiredInputFrameCount(
//             node: *zaudio.Node, 
//             frames_in: ?*[*]const f32, 
//             frame_count_in: ?*u32, 
//             frames_out: *[*]f32, 
//             frame_count_out: *u32) void {
// }

var vtable = zaudio.Node.VTable{
    .onProcess = process_pcm_frames,
    .onGetRequiredInputFrameCount = null,
    .input_bus_count = 5,
    .output_bus_count = 1,
    .flags = .{}
};

const inputChannels = [_]u32{2,2,2,2,2};     // Equal in size to the number of input channels specified in the vtable.
const outputChannels = [_]u32{2};  // Equal in size to the number of output channels specified in the vtable.  
pub fn create(graph: *zaudio.NodeGraph) !*zaudio.Node {
    // Each bus needs to have a channel count specified. To do this you need to specify the channel
    // counts in an array and then pass that into the node config.

    var nodeConfig = zaudio.Node.Config.init();
    nodeConfig.vtable          = &vtable;
    nodeConfig.input_channels  = &inputChannels;
    nodeConfig.output_channels = &outputChannels;

    return try graph.createNode(nodeConfig);
}

pub fn destroy(node: *zaudio.Node) void {
    zaudio.NodeGraph.destroyNode(node);
}
