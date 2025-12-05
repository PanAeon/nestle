const std = @import("std");
const DMA = @This();

pub fn init() DMA {
    return .{};
}

pub fn oam(self: *DMA, data: u8) void {
    _ = &self;
    _ = &data;
}
