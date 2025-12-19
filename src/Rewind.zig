
const std = @import("std");

const Rewind = @This();

dataBuffer: []u8 = undefined,
imageBuffer: []u8 = undefined,
// start: usize = 0,
writeCursor: usize = 0,
numItems: usize = 0,
// imagePos: usize = 0,
itemSize: usize = 0,

const RewindSeconds = 20; // 10 seconds now

const NES_WIDTH: usize = 256;
const NES_HEIGHT: usize = 240;
const ImageBuffSize = NES_WIDTH * NES_HEIGHT * 4;

pub fn init(gpa:std.mem.Allocator, itemSize: u64) !Rewind {
    return .{
        .dataBuffer = try gpa.alloc(u8, RewindSeconds * 30 * itemSize),
        .imageBuffer = try gpa.alloc(u8, RewindSeconds * 30 * ImageBuffSize),
        .itemSize = itemSize
    };
}
pub fn deinit(self: *Rewind, gpa: std.mem.Allocator) void {
    gpa.free(self.dataBuffer);
    gpa.free(self.imageBuffer);
}

pub fn pushData(self: *Rewind, data: []u8) void {
    if (data.len != self.itemSize) {
        @panic("wrong data size\n");
    }
    const writePos = self.writeCursor * self.itemSize;
    @memcpy(self.dataBuffer[writePos..writePos+data.len], data);
    self.writeCursor = (self.writeCursor + 1) % (RewindSeconds * 30);
    self.numItems = @min(self.numItems + 1, RewindSeconds * 30);
}
pub fn pushImageData(self: *Rewind, data: []u8) void {
    if (data.len != ImageBuffSize) {
        @panic("wrong data size\n");
    }
    const writePos = self.writeCursor * ImageBuffSize;
    @memcpy(self.imageBuffer[writePos..writePos+data.len], data);
    // self.writeCursor = (self.writeCursor + 1) % (RewindSeconds * 30);
    // self.numItems = @min(self.numItems + 1, RewindSeconds * 30);
}

pub fn getCursor(self: *Rewind) usize {
    // if (self.numItems == 0) {
        // return 0;
    // } else if (self.numItems < RewindSeconds * 30) {
        // return self.numItems - 1;
    // } else {
       return (RewindSeconds * 30 + self.writeCursor - 1 ) % (RewindSeconds * 30);
    // }
}
pub fn hasNext(self: *Rewind, readCursor: usize) bool {
    return self.numItems > 0 and (readCursor != self.writeCursor);
}
pub fn getNext(self: *Rewind, readCursor: *usize) []u8 {
    const start = readCursor.* * self.itemSize;
    const end = (readCursor.* + 1) * self.itemSize;
    readCursor.* = (RewindSeconds * 30 + readCursor.* - 1) % (RewindSeconds * 30);
    self.numItems -= 1;
    self.writeCursor = (RewindSeconds * 30 + self.writeCursor - 1) % (RewindSeconds * 30);
    return self.dataBuffer[start..end];
}
pub fn getNextImage(self: *Rewind, readCursor: usize) []u8 {
    const start = readCursor * ImageBuffSize;
    const end = (readCursor + 1) * ImageBuffSize;
    return self.imageBuffer[start..end];
}
// pub fn pushImage(self: *Rewind, data: []u8) void {
//     @memcpy(self.imageBuffer[self.imagePos..self.imagePos+data.len], data);
//     self.imagePos = self.imagePos + data.len;
//     if (self.imagePos == self.dataBuffer.len) {
//         self.imagePos = 0;
//     }
// }

