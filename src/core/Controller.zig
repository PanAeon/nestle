const std = @import("std");
const Controller = @This();

pub const JoystickState = packed struct { buttonA: bool = false, buttonB: bool = false, select: bool = false, start: bool = false, up: bool = false, down: bool = false, left: bool = false, right: bool = false };

joystick1: JoystickState = .{},
joystick2: JoystickState = .{},
numReads: u8 = 0,
strobe: bool = false,

pub fn init() Controller {
    return .{};
}

const Output = packed struct(u8) {
    S: bool = false,
    E: bool = false,
    M: bool = false,
    _: u5 = 0 
};
// In the NES and Famicom, the top three (or five) bits are not driven, and so retain
// the bits of the previous byte on the bus. Usually this is the most significant byte
// of the address of the controller port—0x40. Certain games (such as Paperboy)
// rely on this behavior and require that reads from the controller ports return
// exactly $40 or $41 as appropriate
// TODO: openbus
pub fn read(self: *Controller, address: u16) u8 {
    var out: Output = .{};
    // std.debug.print("Joystick read!\n", .{});
    switch (address) {
        0x4016 => {
            if (self.numReads < 8) {
                const bits: u8 = @bitCast(self.joystick1);
                const shift: u3 = @truncate(self.numReads);
                const mask: u8 = @as(u8, 1) << shift;
                out.S = ((bits & mask) >> shift) == 1;
                out._ = 0b10000;
                // if (out.S) {
                    // std.debug.print("button pressed!!{d}\n", .{self.numReads});
                // }
                self.numReads += 1;
            } else {
                out.S = true;
            }
        },
        0x4017 => {
            if (self.numReads < 8) {
                const bits: u8 = @bitCast(self.joystick2);
                const shift: u3 = @truncate(self.numReads);
                const mask: u8 = @as(u8, 1) << shift;
                out.S = ((bits & mask) >> shift) == 1;
                out._ = 0b10000;
                self.numReads += 1;
            } else {
                out.S = true;
            }
        },
        else => {
            std.debug.panic("wrong address 0x{x} for controller", .{address});
        },
    }
    return @bitCast(out);
}

pub fn setStrobe(self: *Controller, data: u8) void {
    self.strobe = (data & 0x1) == 1;
    if (self.strobe) {
        self.numReads = 0;
    }
    // std.debug.print("Joystick strobe!\n", .{});
}
