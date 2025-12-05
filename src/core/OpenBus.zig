const std = @import("std");
const OpenBus = @This();

lastRead: u8 = undefined,

// On a standard NES, reading open bus repeats the last value that was read from
// the bus before this read.
pub fn read(self: *OpenBus, address: u16) u8 {
    _ = &address;
    return self.lastRead;
}
