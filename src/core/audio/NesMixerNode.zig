const std = @import("std");
const zaudio = @import("zaudio");
const NesMixerNode = @This();


pub fn process_pcm_frames(
            node: *zaudio.Node,
            frames_in: ?*[*]const f32,
            frame_count_in: ?*u32,
            frames_out: *[*]f32,
            frame_count_out: *u32,
        ) callconv(.c) void {
    _ = &node;
    if (frames_in != null and frame_count_in != null) {
        var s:f32 = 0;
        for (0..frames_in.?) |f| {
            for (0..5) |i| {
                s += frames_in.?.*[f*5+i];
                frames_out.*[f] = s;
            }
        }
       frame_count_out.* = frames_in.? / 5;
    }
}

// pub fn getRequiredInputFrameCount(
//             node: *zaudio.Node, 
//             frames_in: ?*[*]const f32, 
//             frame_count_in: ?*u32, 
//             frames_out: *[*]f32, 
//             frame_count_out: *u32) void {
// }

const vtable = zaudio.Node.VTable{
    .onProcess = process_pcm_frames,
    .onGetRequiredInputFrameCount = null,
    .input_bus_count = 5,
    .output_bus_count = 1,
    .flags = .{}
};

pub fn create(
     graph: *zaudio.NodeGraph,
     pulse1: zaudio.Channel,
     pulse2: zaudio.Channel,
     triangle: zaudio.Channel,
     noise: zaudio.Channel,
     dmc: zaudio.Channel,
     outputChannel: zaudio.Channel) !*zaudio.Node {
    // Each bus needs to have a channel count specified. To do this you need to specify the channel
    // counts in an array and then pass that into the node config.
    const inputChannels = [_]u32{pulse1, pulse2, triangle, noise, dmc};     // Equal in size to the number of input channels specified in the vtable.
    const outputChannels = [_]u32{outputChannel};  // Equal in size to the number of output channels specified in the vtable.  

    const nodeConfig = zaudio.Node.Config.init();
    nodeConfig.vtable          = &vtable;
    nodeConfig.pInputChannels  = inputChannels;
    nodeConfig.pOutputChannels = outputChannels;

    return try graph.createNode(nodeConfig);
}

pub fn destroy(node: *zaudio.Node) void {
    zaudio.NodeGraph.destroyNode(node);
}
