const std = @import("std");

const Cpu = @import("Cpu.zig");
const Mapper = @import("../mapper/Mapper.zig");
const MemoryController = @import("MemoryController.zig");

// there are exactly three PPU ticks per CPU cycle,
const Ppu = @This();


const TileData = struct {
    nametable: u8 = 0,
    attrTable: u8 = 0,
    patternTableTileLow: u8 = 0,
    patternTableTileHigh: u8 = 0 // 8 bytes above pattern table tile low address
};

const SpriteAttrs = packed struct {
    palette: u2 = 0, //  Palette (4 to 7) of sprite
    _: u3 = 0,
    behindBackground: bool = false, // 0 - in front of bck, 1 - behind
    flipHorisontally: bool = false,
    flipVertically: bool = false,
};

const SpriteData = struct {
    colorIdx: u6,
    spriteIdx: u6,
    behindBackground: bool,
    present: bool
};
// In addition, the PPU internally contains 256 bytes of memory known as
// Object Attribute Memory which determines how sprites are rendered. The CPU
// can manipulate this memory through memory mapped registers
// at OAMADDR ($2003), OAMDATA ($2004), and OAMDMA ($4014).
const Sprite = packed struct { 
    yPosition: u8 = 0, 
    tileIdx: u8 = 0, 
    attrs: SpriteAttrs = .{}, 
    xPosition: u8 = 0 
};
// $0, $4, $8, $C Sprite Y coordinate ???
// $1, $5, $9, $D Sprite tile #
// $2, $6, $A, $E Sprite attribute
// $3, $7, $B, $F Sprite X coordinate

//  ($2000 write)
const PPUCtrl = packed struct {
    baseNametableAddress: u2 = 0, // (0 = $2000; 1 = $2400; 2 = $2800; 3 = $2C00)
    vramAddressIncrement: u1 = 0, // Per cpu read of ppudata,  (0: add 1, going across; 1: add 32, going down)
    spritePatternTableAddress: u1 = 0, // For 8x8 sprites (0: $0000; 1: $1000; ignored in 8x16 mode)
    backgroundPatternTableAddress: u1 = 0, // (0: $0000; 1: $1000)
    spriteSize: u1 = 0, // (0: 8x8 pixels; 1: 8x16 pixels – see PPU OAM#Byte 1)
    PPUMasterSlaveSelect: u1 = 0, //(0: read backdrop from EXT pins; 1: output color on EXT pins)
    VBlankNMIEnable: bool = false,
};
// PPUMASK - Rendering settings ($2001 write)
const PPUMask = packed struct {
    grayscale: bool = false, // 0: normal, 1: grayscale
    showBackgroundLeft: bool = false, // 1: Show background in leftmost 8 pixels of screen, 0: Hide
    showSpritesLeft: bool = false, // 1: Show sprites in leftmost 8 pixels of screen, 0: Hide
    enableBackgroundRendering: bool = true,
    enableSpriteRendering: bool = true,
    emphasizeRed: bool = false, // green on PAL/Dendy
    emphasizeGreen: bool = false,
    empahsizeBlue: bool = false,
};
// PPUSTATUS - Rendering events ($2002 read)
const PPUStatus = packed struct {
    identifier: u5 = 0x11, //(PPU open bus or 2C05 PPU identifier)
    spriteOverflow: bool = false,
    sprite0Hit: bool = false,
    VBlank: bool = false, // Vblank flag, cleared on read. Unreliable
};
const V = packed struct (u15) {
    coarseXScroll:u5 = 0,
    coarseYScroll:u5 = 0,
    verticalNametable:u1 = 0,
    horizontalNametable:u1 = 0,
    fineYScroll:u3 = 0
};
//The PPU starts rendering immediately after power-on or reset,
//but ignores writes to most registers
//(specifically $2000, $2001, $2005 and $2006)
//until reaching the pre-render scanline of the next frame;
//more specifically, for around 29658 NTSC CPU cycles or 33132 PAL CPU cycles,

// registers, CPU $2000 through $2007
ppuCtrl: PPUCtrl = .{}, // W
ppuMask: PPUMask = .{}, // W
ppuStatus: PPUStatus = .{}, //R
oamAddr: u8 = 0, // W
// 64 sprites x 4byte
// oamData: [256]u8 = std.mem.zeroes([256]u8), // RW
// ppuScroll: [2]u8 = .{ 0, 0 }, // Wx2 x scroll then y scroll ... (x is high byte)
ppuData: u8 = 0, // RW
oamDma: u8 = 0, // Write
//
// internal registers:
v: V = .{}, // current VRam index
// yyy NN YYYYY XXXXX
// ||| || ||||| +++++-- coarse X scroll
// ||| || +++++-------- coarse Y scroll
// ||| ++-------------- nametable select
// +++----------------- fine Y scroll
t: V = .{}, // temporary VRam index, can also be thought of as the address of the top left onscreen tile.
t1: u15 = 0, // temporary VRam index, can also be thought of as the address of the top left onscreen tile.
fineXScroll: u3 = 0, //(x) fine x scroll
writeToggle: u1 = 0, // first or second write toggle
sprites: [64]Sprite = .{Sprite{}} ** 64,
currentSprites: [8]Sprite = .{Sprite{}} ** 8,
mapper: Mapper,
palette: [32]u6 = .{0} ** 32,
outputBuffer: []u32, // always 256x240x32
scanline: u32 = 0,
dot:u32 = 0,
tiledata: [4]TileData = std.mem.zeroes([4]TileData),
numfetches:u32 = 0,
scanlineSpriteBuffer: [256]SpriteData = std.mem.zeroes([256]SpriteData),
//
// t,v:
// yyy NN YYYYY XXXXX
// ||| || ||||| +++++-- coarse X scroll
// ||| || +++++-------- coarse Y scroll
// ||| ++-------------- nametable select
// +++----------------- fine Y scroll

cpu: *Cpu = undefined,
memoryController: *MemoryController = undefined,

// The PPU outputs a picture region of 256x240 pixels and a border region extending 16 pixels left, 
// 11 pixels right, and 2 pixels down (283x242)
// PPU performs memory fetches on dots 321-336 and 1-256 of scanlines 0-239 and 261
// each memory fetch takes two dots
// 262 scanlines per frame. Each scanline lasts for 341 PPU clock cycles (113.667 CPU clock cycles; 1 CPU cycle = 3 PPU cycles), with each clock cycle producing one pixel.
// execute cycle by cycle
//  1 CPU cycle = 3 PPU cycles
//   1 clock cycle= 1 pixel.
pub fn startNewFrame(self: *Ppu) void {
    self.scanline = 0;
    self.dot = 0;
}
pub fn renderingEnabled(self: *Ppu) bool {
    return self.ppuMask.enableBackgroundRendering or self.ppuMask.enableSpriteRendering;
}
pub fn incrementX(self: *Ppu) void  {
    if (self.renderingEnabled()) {
    if (self.v.coarseXScroll == 31) {
        self.v.coarseXScroll = 0;
        self.v.horizontalNametable ^= 1;
    } else {
        self.v.coarseXScroll += 1;
    }
    }
}
pub fn incrementY(self: *Ppu) void {
    if (self.renderingEnabled()){
        if (self.v.fineYScroll < 7) {
            self.v.fineYScroll += 1;
        } else {
            self.v.fineYScroll = 0;
            if (self.v.coarseYScroll == 29) {
                self.v.coarseYScroll = 0; 
                self.v.verticalNametable ^= 1; //switch vertical nametable
            } else if (self.v.coarseYScroll == 31) {
                self.v.coarseYScroll = 0;
            } else {
                self.v.coarseYScroll += 1;
            }
        }
    }
}
pub fn copyXPosition(self: *Ppu) void {
    if (self.renderingEnabled()) {
        self.v.coarseXScroll = self.t.coarseXScroll;
        self.v.horizontalNametable = self.t.horizontalNametable;
    }
}
pub fn copyYPosition(self: *Ppu) void {
    if (self.renderingEnabled()) {
        self.v.coarseYScroll = self.t.coarseYScroll;
        self.v.verticalNametable = self.t.verticalNametable;
        self.v.fineYScroll = self.t.fineYScroll;
    }
}
pub fn fetchSprites(self: *Ppu) void {
    self.scanlineSpriteBuffer = std.mem.zeroes([256]SpriteData);
    const scanline = self.scanline;

    var numFound : u8 = 0;
    const spriteHeight:u16 = 8 + @as(u16, self.ppuCtrl.spriteSize) * 8;
    var sprites: [8]Sprite = std.mem.zeroes([8]Sprite);
    var indices: [8]u6 = .{0}**8;

    for (self.sprites, 0..) |sprite, i| {
        if (scanline >= sprite.yPosition and scanline <  (@as(u16, sprite.yPosition) + spriteHeight)) {
            if (numFound < 8) {
              sprites[numFound] = sprite;
              indices[numFound] = @intCast(i);
            }
            numFound += 1;
            if (numFound > 8) {
                numFound = 8;
                self.ppuStatus.spriteOverflow = true;
                break;
            }
        }
    }
    const spritePatternTableAddr: u16 = if (self.ppuCtrl.spriteSize == 0) switch (self.ppuCtrl.spritePatternTableAddress) {
        0 => 0x0000,
        1 => 0x1000,
    } else 0x0000;
    for (0..numFound) |_s| {
        const sprite = sprites[numFound - _s - 1];
        const spriteIdx = indices[numFound - _s - 1];
        const isUpperPart = (self.ppuCtrl.spriteSize == 1) and (scanline >= @as(u16, sprite.yPosition) + 8);
        // std.debug.print("ppu sprite size: {}\n", .{self.ppuCtrl.spriteSize});

        const offset = if (self.ppuCtrl.spriteSize == 0) 
              @as(u16, 16) * sprite.tileIdx + spritePatternTableAddr
            else brk: {
                const table = @as(u16, 0x1000) * (sprite.tileIdx & 0x1);
                const idx = sprite.tileIdx & 0xfe;
                break :brk @as(u16, 16) * idx + table + (16 * @as(u16,@intFromBool(isUpperPart))); 
            };
        const spriteLine = scanline - sprite.yPosition - (8*@as(u8, @intFromBool(isUpperPart)));
        var pixelsLow: u8 = 0;
        var pixelsHigh: u8 = 0;

        if (sprite.attrs.flipVertically) {
            pixelsLow = self.ppu_read(@intCast(offset  - (spriteLine )));
            pixelsHigh |= @as(u8, self.ppu_read(@intCast(offset + 8 - (spriteLine ))));
        } else {
            pixelsLow = self.ppu_read(@intCast(offset + (spriteLine )));
            pixelsHigh |= @as(u8, self.ppu_read(@intCast(offset + 8 + (spriteLine ))));
        }
        for (0..8) |i| {
            const _x: usize = if (sprite.attrs.flipHorisontally) i else 7 - i;
            if (sprite.xPosition + _x < 256) {
                const p0:u1 = @truncate((pixelsLow & (@as(u16,0x1) << @intCast(i))) >> @intCast(i));
                const p1:u1 = @truncate((pixelsHigh & (@as(u16,0x1) << @intCast(i))) >> @intCast(i));
                const px:u2 = @as(u2, p1)*2 + @as(u2,p0);
                if (px != 0) {
                    // const mask: u16 = @as(u16,0b11) << @intCast(i);
                    // const px: u2 = @truncate((pixels & mask) >> @intCast(i));
                    const paletteIdx: PaletteIdx = .{
                                .tilePatternData = px,
                                .paletteNumFromAttr = sprite.attrs.palette,
                                .isSprite = true,
                            };
                    const colorIdx: u6 = @truncate(self.ppu_read(@as(u16, 0x3F00) + @as(u5, @bitCast(paletteIdx))));
                    self.scanlineSpriteBuffer[sprite.xPosition + _x] = .{
                        .colorIdx = colorIdx,
                        .spriteIdx = spriteIdx,
                        .behindBackground = sprite.attrs.behindBackground,
                        .present = true,
                    };
                }

            }
        }

    }
}
pub fn fetchTileData(self: *Ppu) void  {
    // Conceptually, the PPU does this 33 times for each scanline:
    //
    // Fetch a nametable entry from $2000-$2FFF.
    // Fetch the corresponding attribute table entry from $23C0-$2FFF and increment the current VRAM address within the same row.
    // Fetch the low-order byte of an 8x1 pixel sliver of pattern table from $0000-$0FF7 or $1000-$1FF7.
    // Fetch the high-order byte of this sliver from an address 8 bytes higher.
    // Turn the attribute data and the pattern table data into palette indices, 
    // and combine them with data from sprite data using priority.

// It also does a fetch of a 34th (nametable, attribute, pattern) tuple that is never used, but some mappers rely on this fetch for timing purposes.
    
    const nametableAddr: u16 = 0x2000 + 
              (0x800 * @as(u16, self.v.verticalNametable)) + 
              (0x400 * @as(u16, self.v.horizontalNametable)) +
              @as(u16, self.v.coarseYScroll) * 32 +
              self.v.coarseXScroll;
    
    const attrTableAddress = 0x23C0 + 
              (0x800 * @as(u16, self.v.verticalNametable)) + 
              (0x400 * @as(u16, self.v.horizontalNametable)) +
              8 * (@as(u16, self.v.coarseYScroll) / 4) +
              (self.v.coarseXScroll / 4);
    const attrData = self.ppu_read(attrTableAddress);

    const dy: u1 = @intCast((self.v.coarseYScroll % 4) / 2);
    const dx: u1 = @intCast(((self.v.coarseXScroll ) % 4) / 2);
    // now we need select 2 bits,
    // value = (bottomright << 6) | (bottomleft << 4) | (topright << 2) | (topleft << 0)
    const bitAddr: u3 = 2 * (@as(u3, dy) * 2 + dx);
    const res: u2 = @truncate((attrData >> bitAddr) & 0x3);
    self.tiledata[0].nametable = self.ppu_read(nametableAddr);
    self.tiledata[0].attrTable = res;
    const bgPatternTableAddr: u16 = @as(u16, self.ppuCtrl.backgroundPatternTableAddress) * 0x1000;
    const patternTableAddr = @as(u16, 16) * self.tiledata[0].nametable + bgPatternTableAddr +  self.v.fineYScroll;
    self.tiledata[0].patternTableTileLow = self.ppu_read(patternTableAddr );
    self.tiledata[0].patternTableTileHigh = self.ppu_read(patternTableAddr + 8);
        self.tiledata[3] = self.tiledata[2]; // FIXME: why delay is 4?
        self.tiledata[2] = self.tiledata[1];
        self.tiledata[1] = self.tiledata[0];

    // self.numfetches+=1;
    if (self.v.coarseXScroll == 8 and self.v.coarseYScroll == 8) {
        // std.debug.print("> nametable adr: 0x{x}\n", .{nametableAddr});
        // std.debug.print("> tile idx: 0x{x}\n", .{self.tiledata[0].nametable});
        // std.debug.print("> patternTableAddr adr: 0x{x}\n", .{patternTableAddr});
        // std.debug.print(">> {x} {x}\n", .{self.tiledata[0].patternTableTileLow, self.tiledata[0].patternTableTileHigh});
    }
     self.incrementX();
}
//341 PPU clock cycles
// for now all-in-one will do
pub fn drawVisibleScanline(self: *Ppu) void {
    // if (self.dot == 0) {
    //     std.debug.print("num fetches: {d}\n", .{self.numfetches});
    //     self.numfetches = 0;
    // }
    // if (self.dot >= 9 and self.dot <= 257 and (self.dot % 8 == 1)) {
    //     self.shiftRegisters();
    // }
    if (self.dot == 321 or self.dot == 329 or (self.dot >= 1 and self.dot < 256 and (self.dot % 8 == 1))) {  // fetch tile data
        self.fetchTileData();
    }
    // The shifters are reloaded during ticks 9, 17, 25, ..., 257. 
    if ((self.dot >= 9) and (self.dot <= 257) and (self.dot % 8 == 1)) {
        // self.tiledata[3] = self.tiledata[2];
        // self.tiledata[2] = self.tiledata[1];
        // self.tiledata[1] = self.tiledata[0];
    }
    if (self.dot >= 257 and self.dot <= 320) {
        self.oamAddr = 0;
    }
    if (self.dot == 256 ) {
        self.incrementY();
    }
    if (self.dot == 0 and  self.scanline < 240) {
        self.fetchSprites();
    }
    if (self.dot == 257 ) {
        self.copyXPosition();
    }
    if (self.dot == 328 or self.dot == 336 or (self.dot >= 8 and self.dot <= 256 and (self.dot % 8 == 0)) ) {
         // self.incrementX();
    }
    if (self.dot >= self.fineXScroll and self.dot < (256+8)) {
        const tileData = self.tiledata[3];
        const xscroll:u3 = @truncate((8  - (self.dot % 8) ) );
        const lowPixel:u1 = @truncate(tileData.patternTableTileLow >> (xscroll));
        const highPixel:u1 = @truncate(tileData.patternTableTileHigh >> (xscroll));
        const pixel: u2 = ((@as(u2, lowPixel) ) + (@as(u2, highPixel) << 1));
            const x = self.dot  - self.fineXScroll;// - 16;
            const y = self.scanline;

            const paletteIdx: PaletteIdx = .{
                            .tilePatternData = pixel,
                            .paletteNumFromAttr = @truncate(self.tiledata[3].attrTable),
                            .isSprite = false,
                        };
            const colorIdx: u6 = @truncate(self.ppu_read(@as(u16, 0x3F00) + @as(u5, @bitCast(paletteIdx))));
            // const colour = SystemPalette[colorIdx];
            if (x < 256 and y < 240) {
                const pos = y*256+x;
                // const _colours: [4]u32 = .{ 0xFF000000, 0xFF777777, 0xFFA0A0A0, 0xFFFFFFFF };
                // const colour = _colours[pixel];
                const sd = self.scanlineSpriteBuffer[x];
                if (pixel == 0) {
                   // draw backdrop
                   if ( !sd.present ) {
                       self.outputBuffer[pos] = SystemPalette[self.palette[0]];
                   } else {
                       self.outputBuffer[pos] = SystemPalette[sd.colorIdx];
                   }
                } else {
                   if (sd.present and sd.spriteIdx == 0) {
                       self.ppuStatus.sprite0Hit = true;
                   }
                   if (!sd.present or sd.behindBackground) {
                       self.outputBuffer[pos] = SystemPalette[colorIdx];
                   } else {
                       self.outputBuffer[pos] = SystemPalette[sd.colorIdx];
                   }
                }
                // self.outputBuffer[pos] = colour;
                // if (sd.present) {
                    // if (sd.spriteIdx == 0 and colorIdx != 0) {
                    //    self.ppuStatus.sprite0Hit = true;
                    // }
                     // std.debug.print("hooray?", .{});
                    // const c = SystemPalette[sd.colorIdx];
                    
                    // self.outputBuffer[pos] =  c;
                // }
            }

    }
}

pub fn run(self: *Ppu) void {
    switch (self.scanline) {
        0...239 => {
            if (self.scanline == 0 and self.dot == 0) {
                self.ppuStatus.VBlank = false;
                // std.debug.print("scaline 0,0>\n", .{});
            }
            self.drawVisibleScanline();
        },
        240 => {}, // post-render scanline, ppu idles here
        241...260 => {
            if (self.scanline == 241 and self.dot == 1) {
                // std.debug.print("scaline 241,1> **nmi**\n", .{});
                self.ppuStatus.VBlank = true;
                if (self.ppuCtrl.VBlankNMIEnable) {
                    self.cpu.nmi();
                }
            }
            // The PPU makes no memory accesses during these scanlines
        },
        261 => {
            if (self.dot >= 280 and self.dot <= 304) {
                self.copyYPosition();
            }
            if (self.dot == 0) {
                self.ppuStatus.spriteOverflow = false;
                self.ppuStatus.sprite0Hit = false;
                // std.debug.print("scaline 261,0> -1 scanline\n", .{});
            }
            self.drawVisibleScanline();
            // if (self.dot == 0) {
            //     self.drawSprites();
            // }
        }, // pre-rendeer, During pixels 280 through 304 of this scanline, the vertical scroll bits are reloaded if rendering is enabled.  
        262,263,264 => {}, // ignore
        else => {std.debug.print("out of scanlines: {d}\n", .{self.scanline});},
    }
    self.dot +=1;
    if (self.dot > 340) {
        self.scanline += 1;
        self.dot = 0;
    }
}

pub fn init(mapper: Mapper, outputBuffer: []u32) Ppu {
    return .{ .mapper = mapper, .outputBuffer = outputBuffer };
}

pub fn read(self: *Ppu, addr: u16) u8 {
    switch (addr) {
        0x2000 => return 0, // w
        0x2001 => return 0, // w
        0x2002 => {
            // self.ppuStatus.x = 0x1F;
            // self.ppuStatus.VBlank +%= 1;
            const res: u8 = @bitCast(self.ppuStatus);
            self.ppuStatus.VBlank = false;
            self.writeToggle = 0;
            return res;
        }, // read resets write-pair for $2005/$2006
        0x2003 => return 0,
        // 0x2004 => return self.oamData[self.oamAddr], //OAM R/W
        0x2004 => {
            const bytes: []u8 = @ptrCast(&self.sprites);
            return bytes[self.oamAddr];
        }, //OAM R/W
        0x2005 => return 0, // Wx2
        0x2006 => return 0, // Wx2
        0x2007 => {
            var v: u15 = @bitCast(self.v);
            const res = self.ppu_read(v);
            const incr = self.ppuCtrl.vramAddressIncrement;
            v +%= (~incr + (incr * @as(u15, 32)));
            self.v = @bitCast(v);
            return res;
        }, // R/W Vram data
        else => std.debug.panic("wrong address 0x{x} for PPU", .{addr}),
    }
}

pub fn write(self: *Ppu, addr: u16, data: u8) void {
    switch (addr) {
        0x2000 => {
            self.ppuCtrl = @bitCast(data);
            if (self.ppuCtrl.VBlankNMIEnable and self.ppuStatus.VBlank) {
                self.cpu.nmi();
            }
            self.t.horizontalNametable = @truncate(self.ppuCtrl.baseNametableAddress);
            self.t.verticalNametable = @truncate(self.ppuCtrl.baseNametableAddress >> 1);
            // std.debug.print("PPU: write to CTRL, {any}\n", .{self.ppuCtrl});
        }, // TODO: writes to this register are ignored until the first pre-render scanline.
        0x2001 => self.ppuMask = @bitCast(data), // w
        0x2002 => {}, // ??
        0x2003 => self.oamAddr = data,
        0x2004 => {
            const bytes: []u8 = @ptrCast(&self.sprites);
            bytes[self.oamAddr] = data;
            self.oamAddr +%= 1; // FIXME: set oamAddr to 0 OAMADDR is set to 0 during each of ticks 257–320 (the sprite tile loading interval) of the pre-render and visible scanlines. 
        }, //OAM R/W
        0x2005 => {
            if (self.writeToggle == 0) {
                self.t.coarseXScroll = @truncate(data >> 3); 
                self.fineXScroll = @truncate(data);
            } else {
                self.t.coarseYScroll = @truncate(data >> 3);
                self.t.fineYScroll = @truncate(data); 
            }
            // self.ppuScroll[self.writeToggle] = data;
            self.writeToggle +%= 1;
        }, // Wx2
        0x2006 => { // PPUAddr
            if (self.writeToggle == 0) { // FIXME: t or v?
                // high byte first
                var t: u15 = @bitCast(self.t);
                t = (t & 0x00FF) | (@as(u15, data) << 8) & 0x3fff;
                self.t = @bitCast(t);
                // self.t1 = (self.t1 & 0x00FF) | (@as(u15, data) << 8) & 0x3fff;
            } else {
                var t: u15 = @bitCast(self.t);
                t = t & (0x7F00) | @as(u15, data);
                self.t = @bitCast(t);
                // self.t1 = self.t1 & (0x7F00) | @as(u15, data);
            }
            self.writeToggle +%= 1;
        }, // Wx2
        0x2007 => { //PPUDATA - VRAM data
            var t: u15 = @bitCast(self.t);
            self.ppu_write(@truncate(t), data);
            const incr = self.ppuCtrl.vramAddressIncrement;
            t +%= (~incr + (incr * @as(u15, 32)));
            self.t = @bitCast(t);
            if (self.t1 >= 0x1140 and self.t1 < 0x1148) {
                std.debug.print("0x114x data: 0x{x}\n", .{data});
            }
            // self.ppu_write(self.t1, data);
            // const incr = self.ppuCtrl.vramAddressIncrement;
            // self.t1 +%= (~incr + (incr * @as(u15, 32)));
        },
        else => std.debug.panic("wrong address 0x{x} for PPU", .{addr}),
    }
}

//The PPU addresses a 14-bit (16kB) address space, $0000-$3FFF, completely separate
//from the CPU's address bus. It is either directly accessed by the PPU itself,
// or via the CPU with memory mapped registers at $2006 and $2007.
pub fn ppu_read(self: *Ppu, addr: u16) u8 {
    const _addr: u14 = @truncate(addr);
    switch (_addr) {
        0x0000...0x3EFF => {
            const res = self.mapper.ppu_read(_addr);
            // if (addr >= 3*16 and addr < 4*16) {
            // std.debug.print("ppu read: 0x{x}, data: 0x{x}\n", .{addr, res});
            // }
            return res;
        },
        0x3F00...0x3F1F => return self.palette[_addr - 0x3F00], // palette ram indexes
        0x3F20...0x3FFF => return self.palette[(_addr - 0x3f20) % 32], // mirrors of 0x3F00-0x3F1F
    }
}
pub fn ppu_write(self: *Ppu, addr: u14, data: u8) void {
    // if (addr >= 3*16 and addr < 4*16) {
    // std.debug.print("ppu write: 0x{x}, data: 0x{x}\n", .{addr, data});
    // }
    switch (addr) {
        0x0000...0x3EFF => self.mapper.ppu_write(addr, data),
        0x3F00...0x3F1F => {
            const d = @as(u6, @truncate(data));
            if (addr == 0x3F00) {
                self.palette[0x0010] = d;
            } else if (addr == 0x3f10) {
                self.palette[0x0000] = d;
            }
            // if (addr == 0x3f11) {
            // std.debug.print("palette write: addr: 0x{x}, val: 0x{x}\n", .{_addr, data});
            //   self.cpu.print();
            //   @panic("gotcha\n");
            //   // self.cpu.PC
            // }
            self.palette[addr - 0x3f00] = d;
        }, // palette ram indexes
        0x3F20...0x3FFF => self.palette[(addr - 0x3f20) % 32] = @truncate(data), // mirrors of 0x3F00-0x3F1F
    }
}
// $0000-$0FFF $1000 Pattern table 0 Cartridge
// $1000-$1FFF $1000 Pattern table 1 Cartridge
// $2000-$23BF $03c0 Nametable 0         Cartridge
// $23C0-$23FF $0040 Attribute table 0 Cartridge
// $2400-$27BF $03c0 Nametable 1         Cartridge
// $27C0-$27FF $0040 Attribute table 1 Cartridge
// $2800-$2BBF $03c0 Nametable 2         Cartridge
// $2BC0-$2BFF $0040 Attribute table 2 Cartridge
// $2C00-$2FBF $03c0 Nametable 3         Cartridge
// $2FC0-$2FFF $0040 Attribute table 3 Cartridge
// $3000-$3EFF $0F00 Unused                 Cartridge
// $3F00-$3F1F $0020 Palette RAM indexes Internal to PPU
// $3F20-$3FFF $00E0 Mirrors of $3F00-$3F1F Internal to PPU
//
//
// The NES has 2kB of RAM dedicated to the PPU, usually mapped to the nametable
// address space from $2000-$2FFF,
// takes 513/514 cycles..
pub fn oamdma(self: *Ppu, data: u8) void {
    // 0x4014 W  OAM DMA high address
    // Copy 256 bytes from $xx00-$xxFF into OAM via OAMDATA ($2004)
    var addr: u16 = @as(u16, data) << 8;
    // std.debug.print("cpu_addr: 0x{x}\n", .{addr});
    // std.debug.print("ppu_addr: 0x{x}\n", .{self.ppuAddr});
    // std.debug.print("oamdma 0x{x}!!\n", .{data});
    for (0..256) |_| {
        const foo = self.memoryController.read(addr);
        self.memoryController.write(0x2004, foo);
        addr += 1;
    }
    self.cpu.dmaDone = true;
}
// see https://github.com/lukexor/tetanes/blob/main/tetanes-core/src/video.rs
// for actual palette generation code
// const NTSCPalette = [512]u32{ 0xFF000000, 0xFF000016, 0xFF040235, 0xFF01004B, 0xFF07046A, 0xFF050180, 0xFF0B069F, 0xFF0903B5, 0xFF1A0003, 0xFF200521, 0xFF1E0237, 0xFF240756, 0xFF22046C, 0xFF28098B, 0xFF2506A1, 0xFF2B0BC0, 0xFF3D080D, 0xFF3B0524, 0xFF400A42, 0xFF3E0759, 0xFF440C77, 0xFF42098D, 0xFF480EAC, 0xFF450BC2, 0xFF570910, 0xFF550526, 0xFF5B0A45, 0xFF59075B, 0xFF5E0C7A, 0xFF5C0990, 0xFF620EAF, 0xFF600BC5, 0xFF720913, 0xFF770E31, 0xFF750B48, 0xFF7B1066, 0xFF790C7C, 0xFF7F119B, 0xFF7C0EB1, 0xFF8213D0, 0xFF94111E, 0xFF920E34, 0xFF981352, 0xFF951069, 0xFF9B1587, 0xFF99129E, 0xFF9F17BC, 0xFF9D13D2, 0xFFAE1120, 0xFFAC0E36, 0xFFB21355, 0xFFB0106B, 0xFFB6158A, 0xFFB312A0, 0xFFB917BF, 0xFFB714D5, 0xFFC91123, 0xFFCF1641, 0xFFCC1358, 0xFFD21876, 0xFFD0158C, 0xFFD61AAB, 0xFFD417C1, 0xFFDA1CE0, 0xFF092408, 0xFF07211E, 0xFF0D263D, 0xFF0A2353, 0xFF102872, 0xFF0E2588, 0xFF142AA7, 0xFF1127BD, 0xFF23240B, 0xFF212121, 0xFF27263F, 0xFF252356, 0xFF2A2874, 0xFF28258B, 0xFF2E2AA9, 0xFF2C27BF, 0xFF3E240D, 0xFF43292C, 0xFF412642, 0xFF472B61, 0xFF452877, 0xFF4B2D95, 0xFF482AAC, 0xFF4E2FCA, 0xFF602C18, 0xFF5E292E, 0xFF642E4D, 0xFF612B63, 0xFF673082, 0xFF652D98, 0xFF6B32B7, 0xFF692FCD, 0xFF7A2D1B, 0xFF782931, 0xFF7E2E50, 0xFF7C2B66, 0xFF823084, 0xFF7F2D9B, 0xFF8532B9, 0xFF832FD0, 0xFF952D1D, 0xFF9B323C, 0xFF982F52, 0xFF9E3471, 0xFF9C3087, 0xFFA236A6, 0xFFA032BC, 0xFFA637DA, 0xFFB73528, 0xFFB5323E, 0xFFBB375D, 0xFFB93473, 0xFFBF3992, 0xFFBC36A8, 0xFFC23BC7, 0xFFC038DD, 0xFFD2352B, 0xFFCF3241, 0xFFD53760, 0xFFD33476, 0xFFD93994, 0xFFD736AB, 0xFFDC3BC9, 0xFFDA38E0, 0xFF0A4008, 0xFF0F4526, 0xFF0D423D, 0xFF13475B, 0xFF114471, 0xFF174990, 0xFF1445A6, 0xFF1A4AC5, 0xFF2C4813, 0xFF2A4529, 0xFF304A47, 0xFF2D475E, 0xFF334C7C, 0xFF314993, 0xFF2F46A9, 0xFF354BC7, 0xFF464815, 0xFF44452B, 0xFF4A4A4A, 0xFF484760, 0xFF4E4C7F, 0xFF4B4995, 0xFF514EB4, 0xFF4F4BCA, 0xFF614818, 0xFF674D36, 0xFF644A4D, 0xFF6A4F6B, 0xFF684C81, 0xFF6E51A0, 0xFF6C4EB6, 0xFF7253D5, 0xFF835123, 0xFF814D39, 0xFF875257, 0xFF854F6E, 0xFF8B548C, 0xFF8851A3, 0xFF864EB9, 0xFF8C53D7, 0xFF9E5125, 0xFF9B4D3C, 0xFFA1535A, 0xFF9F4F70, 0xFFA5548F, 0xFFA351A5, 0xFFA856C4, 0xFFA653DA, 0xFFB85128, 0xFFBE5646, 0xFFBC535D, 0xFFC1587B, 0xFFBF5592, 0xFFC55AB0, 0xFFC356C6, 0xFFC95CE5, 0xFFDA5933, 0xFFD85649, 0xFFDE5B68, 0xFFDC587E, 0xFFD95594, 0xFFDF5AB3, 0xFFDD57C9, 0xFFE35CE8, 0xFF126410, 0xFF106126, 0xFF166645, 0xFF14625B, 0xFF1A6779, 0xFF176490, 0xFF1D69AE, 0xFF1B66C5, 0xFF2D6412, 0xFF336931, 0xFF306647, 0xFF366B66, 0xFF34687C, 0xFF3A6D9B, 0xFF3869B1, 0xFF3E6FCF, 0xFF476415, 0xFF4D6933, 0xFF4B664A, 0xFF516B68, 0xFF4E687F, 0xFF546D9D, 0xFF526AB3, 0xFF586FD2, 0xFF6A6C20, 0xFF676936, 0xFF6D6E55, 0xFF6B6B6B, 0xFF717089, 0xFF6F6DA0, 0xFF7472BE, 0xFF726FD5, 0xFF846C22, 0xFF8A7141, 0xFF886E57, 0xFF8D7376, 0xFF8B708C, 0xFF9175AB, 0xFF8F72C1, 0xFF9577DF, 0xFF9E6C25, 0xFFA47144, 0xFFA26E5A, 0xFFA87378, 0xFFA6708F, 0xFFAB75AD, 0xFFA972C4, 0xFFAF77E2, 0xFFC17530, 0xFFBE7246, 0xFFC47765, 0xFFC2737B, 0xFFC8799A, 0xFFC675B0, 0xFFCC7ACE, 0xFFC977E5, 0xFFDB7532, 0xFFE17A51, 0xFFDF7767, 0xFFE57C86, 0xFFE2799C, 0xFFE87EBB, 0xFFE67BD1, 0xFFEC80F0, 0xFF137F0F, 0xFF19842E, 0xFF178144, 0xFF1D8663, 0xFF1A8379, 0xFF208898, 0xFF1E85AE, 0xFF248ACD, 0xFF36881A, 0xFF338531, 0xFF398A4F, 0xFF378665, 0xFF3D8C84, 0xFF3B889A, 0xFF418DB9, 0xFF3E8ACF, 0xFF50881D, 0xFF568D3B, 0xFF548A52, 0xFF598F70, 0xFF578C87, 0xFF5D91A5, 0xFF5B8EBB, 0xFF6193DA, 0xFF6A8820, 0xFF708D3E, 0xFF6E8A54, 0xFF748F73, 0xFF728C89, 0xFF7791A8, 0xFF758EBE, 0xFF7B93DD, 0xFF8D902A, 0xFF8B8D41, 0xFF90925F, 0xFF8E8F76, 0xFF949494, 0xFF9291AA, 0xFF9896C9, 0xFF9593DF, 0xFFA7902D, 0xFFAD954C, 0xFFAB9262, 0xFFB19780, 0xFFAE9497, 0xFFB499B5, 0xFFB296CC, 0xFFB89BEA, 0xFFC19030, 0xFFC7964E, 0xFFC59264, 0xFFCB9783, 0xFFC99499, 0xFFCF99B8, 0xFFCC96CE, 0xFFD29BED, 0xFFE4993A, 0xFFE29651, 0xFFE89B6F, 0xFFE59886, 0xFFEB9DA4, 0xFFE999BA, 0xFFEF9ED9, 0xFFED9BEF, 0xFF1CA317, 0xFF22A836, 0xFF20A54C, 0xFF26AA6B, 0xFF23A781, 0xFF29ACA0, 0xFF27A9B6, 0xFF25A6CC, 0xFF36A31A, 0xFF3CA939, 0xFF3AA54F, 0xFF40AA6D, 0xFF3EA784, 0xFF43ACA2, 0xFF41A9B9, 0xFF47AED7, 0xFF59AC25, 0xFF57A93B, 0xFF5CAE5A, 0xFF5AAB70, 0xFF60B08F, 0xFF5EACA5, 0xFF64B2C3, 0xFF61AEDA, 0xFF73AC28, 0xFF79B146, 0xFF77AE5C, 0xFF7DB37B, 0xFF7AB091, 0xFF78ADA8, 0xFF7EB2C6, 0xFF7CAEDC, 0xFF8DAC2A, 0xFF93B149, 0xFF91AE5F, 0xFF97B37E, 0xFF95B094, 0xFF9BB5B2, 0xFF98B2C9, 0xFF9EB7E7, 0xFFB0B435, 0xFFAEB14B, 0xFFB4B66A, 0xFFB1B380, 0xFFB7B89F, 0xFFB5B5B5, 0xFFBBBAD4, 0xFFB9B7EA, 0xFFCAB438, 0xFFD0B956, 0xFFCEB66C, 0xFFD4BB8B, 0xFFD2B8A1, 0xFFCFB5B8, 0xFFD5BAD6, 0xFFD3B7EC, 0xFFE5B53A, 0xFFEBBA59, 0xFFE8B66F, 0xFFEEBB8E, 0xFFECB8A4, 0xFFF2BDC2, 0xFFF0BAD9, 0xFFF5BFF7, 0xFF25C71F, 0xFF23C436, 0xFF28C954, 0xFF26C66B, 0xFF2CCB89, 0xFF2AC89F, 0xFF30CDBE, 0xFF2DCAD4, 0xFF3FC722, 0xFF3DC438, 0xFF43C957, 0xFF40C66D, 0xFF46CB8C, 0xFF44C8A2, 0xFF4ACDC1, 0xFF48CAD7, 0xFF59C825, 0xFF5FCD43, 0xFF5DC959, 0xFF63CF78, 0xFF61CB8E, 0xFF67D0AD, 0xFF64CDC3, 0xFF6AD2E2, 0xFF7CD02F, 0xFF7ACD46, 0xFF80D264, 0xFF7DCF7B, 0xFF83D499, 0xFF81D1AF, 0xFF87D6CE, 0xFF85D2E4, 0xFF96D032, 0xFF94CD48, 0xFF9AD267, 0xFF98CF7D, 0xFF9ED49C, 0xFF9BD1B2, 0xFFA1D6D1, 0xFF9FD3E7, 0xFFB1D035, 0xFFB7D553, 0xFFB4D26A, 0xFFBAD788, 0xFFB8D49E, 0xFFBED9BD, 0xFFBCD6D3, 0xFFC1DBF2, 0xFFD3D840, 0xFFD1D556, 0xFFD7DA74, 0xFFD5D78B, 0xFFDADCA9, 0xFFD8D9C0, 0xFFDEDEDE, 0xFFDCDBF4, 0xFFEED842, 0xFFEBD558, 0xFFF1DA77, 0xFFEFD78D, 0xFFF5DCAC, 0xFFF2D9C2, 0xFFF8DEE1, 0xFFF6DBF7, 0xFF25E31F, 0xFF2BE83E, 0xFF29E554, 0xFF2FEA73, 0xFF2DE789, 0xFF33ECA7, 0xFF30E9BE, 0xFF36EEDC, 0xFF48EB2A, 0xFF46E840, 0xFF4CED5F, 0xFF49EA75, 0xFF4FEF94, 0xFF4DECAA, 0xFF53F1C9, 0xFF51EEDF, 0xFF62EC2D, 0xFF60E843, 0xFF66ED61, 0xFF64EA78, 0xFF6AEF96, 0xFF67ECAD, 0xFF6DF1CB, 0xFF6BEEE1, 0xFF7DEC2F, 0xFF83F14E, 0xFF80EE64, 0xFF86F383, 0xFF84EF99, 0xFF8AF4B7, 0xFF88F1CE, 0xFF8DF6EC, 0xFF9FF43A, 0xFF9DF150, 0xFFA3F66F, 0xFFA1F385, 0xFFA6F8A4, 0xFFA4F5BA, 0xFFAAFAD9, 0xFFA8F6EF, 0xFFBAF43D, 0xFFB7F153, 0xFFBDF672, 0xFFBBF388, 0xFFC1F8A6, 0xFFBFF5BD, 0xFFC4FADB, 0xFFC2F7F2, 0xFFD4F43F, 0xFFDAF95E, 0xFFD7F674, 0xFFDDFB93, 0xFFDBF8A9, 0xFFE1FDC8, 0xFFDFFADE, 0xFFE5FFFC, 0xFFF6FC4A, 0xFFF4F960, 0xFFFAFE7F, 0xFFF8FB95, 0xFFFEFFB4, 0xFFFBFDCA, 0xFFFFFFE9, 0xFFFFFFFF };
// const SystemPalette = [64]u32 {
//     0xFF757575, 0xFF271B8F,
// };
// const SystemPalette = [64]u32{
//     (0xFF545454), (0xFF3C1800), (0xFF540400), (0xFF5C0030), (0xFF440064), (0xFF300088), (0xFF081090), (0xFF001E74), (0xFF00323C), (0xFF083A00), (0xFF004000), (0xFF003C00), (0xFF202A00), (0xFF000000), (0xFF000000), (0xFF000000),
//     (0xFF989698), (0xFF783C00), (0xFF982220), (0xFFA01464), (0xFF8814B0), (0xFF5C1EE4), (0xFF3032EC), (0xFF084CC4), (0xFF006678), (0xFF287200), (0xFF087C00), (0xFF007628), (0xFF545A00), (0xFF000000), (0xFF000000), (0xFF000000),
//     (0xFFECEEEC), (0xFFD48820), (0xFFEC6A64), (0xFFEC58B4), (0xFFE454EC), (0xFFB062EC), (0xFF787CEC), (0xFF4C9AEC), (0xFF38B4CC), (0xFF74C400), (0xFF4CD020), (0xFF38CC6C), (0xFFA0AA00), (0xFF3C3C3C), (0xFF000000), (0xFF000000),
//     (0xFFECEEEC), (0xFFE4C490), (0xFFECB4B0), (0xFFECAED4), (0xFFECAEEC), (0xFFD4B2EC), (0xFFBCBCEC), (0xFFA8CCEC), (0xFFA0D6E4), (0xFFB4DE78), (0xFFA8E290), (0xFF98E2B4), (0xFFCCD278), (0xFFA0A2A0), (0xFF000000), (0xFF000000),
// };
const pal = @embedFile("Digital Prime (FBX).pal");
const SystemPalette: [64]u32 = brk: {
    var arr: [64]u32 = .{0xFF000000}**64;
    for (0..64)|i| {
        arr[i] = 0xFF000000 + @as(u32, pal[i*3]) + (@as(u32, pal[i*3+1]) << 8) + (@as(u32, pal[i*3+2]) << 16); 
    }
    break :brk arr;
};

// const SystemPalette: []const u24 = @alignCast(@ptrCast(pal)); // why not working?

// Backgrounds and sprites each have 4 palettes of 4 colors, located at $3F00-$3F1F in VRAM
// draw entire frame for simplicity
pub fn nameTableAddress(self: *Ppu, row: u16, col: u16) u16 {
    const scrlly = (self.ppuScroll[1]); // 0..255
    const scrllx = (self.ppuScroll[0]); // 0..255
    const tileYOffset = scrlly / 8;
    const tileXOffset = scrllx / 8;
    var nametableAddr: u16 = switch (self.ppuCtrl.baseNametableAddress) {
        0 => 0x2000,
        1 => 0x2400,
        2 => 0x2800,
        3 => 0x2C00,
    };
    var newOffset = (row + tileYOffset) % (30 * 2); // i hope
    if (newOffset > 29) {
        nametableAddr = if (nametableAddr == 0x2000) 0x2800 else 0x2000;
        newOffset = newOffset - 30;
    }
    var newXOffset = (col + tileXOffset) % (32 * 2); // i hope
    if (newXOffset > 31) {
        nametableAddr = if (nametableAddr == 0x2000) 0x2400 else 0x2000;
        newXOffset = newXOffset - 32;
    }
    const address = nametableAddr + newOffset * 32 + newXOffset; //tileIdx
    return address;
}

pub fn getAttrValue2(self: *Ppu, row: usize, col: usize) u2 {
    const scrlly = (self.ppuScroll[1]); // 0..255
    const scrllx = (self.ppuScroll[0]); // 0..255
    const tileYOffset = scrlly / 8;
    const tileXOffset = scrllx / 8;
    var nametableAddr: u16 = switch (self.ppuCtrl.baseNametableAddress) {
        0 => 0x2000,
        1 => 0x2400,
        2 => 0x2800,
        3 => 0x2C00,
    };
    _ = &nametableAddr;
    var newOffset = (row + tileYOffset) % (30 * 2); // i hope
    if (newOffset > 29) {
        nametableAddr = if (nametableAddr == 0x2000) 0x2800 else 0x2000;
        newOffset = newOffset - 30;
    }
    var newXOffset = (col + tileXOffset) % (32 * 2); // i hope
    if (newXOffset > 31) {
        nametableAddr = if (nametableAddr == 0x2000) 0x2400 else 0x2000;
        newXOffset = newXOffset - 32;
    }
    const attrTableAddress = nametableAddr + 0x03C0;
    // const address = nametableAddr + newOffset * 32 + newXOffset; //tileIdx
    // return  address;
    const address = attrTableAddress + (8 * (newOffset / 4)) + (newXOffset / 4); //tileIdx
    // if (col == 11 and row == 7) {
    //     std.debug.print(">> attr addr: 0x{x}\n", .{address});
    // }
    const b = self.ppu_read(@truncate(address));
    const dy: u1 = @intCast((newOffset % 4) / 2);
    const dx: u1 = @intCast((newXOffset % 4) / 2);
    // now we need select 2 bits,
    // value = (bottomright << 6) | (bottomleft << 4) | (topright << 2) | (topleft << 0)
    const bitAddr: u3 = 2 * (@as(u3, dy) * 2 + dx);
    const res: u2 = @truncate((b >> bitAddr) & 0x3);
    return res;
}


// 4bit0
// -----
// SAAPP
// |||||
// |||++- Pixel value from tile pattern data
// |++--- Palette number from attributes
// +----- Background/Sprite select
const PaletteIdx = packed struct(u5) { tilePatternData: u2, paletteNumFromAttr: u2, isSprite: bool };

pub fn drawFrame(self: *Ppu) void {
    for (self.outputBuffer) |*b| {
        b.* = 0;
    }
    // std.debug.print(">> pal length: {d}\n", .{pal.len});
    // std.debug.print(">>scroll x: {d}, y: {d}\n", .{self.ppuScroll[0], self.ppuScroll[1]});
    const bgPatternTableAddr: u16 = switch (self.ppuCtrl.backgroundPatternTableAddress) {
        0 => 0x0000,
        1 => 0x1000,
    };
    // const nametableAddress: u16 = switch (self.ppuCtrl.baseNametableAddress) {
    //     0 => 0x2000,
    //     1 => 0x2400,
    //     2 => 0x2800,
    //     3 => 0x2C00,
    // };
    // const attrTableAddress: u16 = switch (self.ppuCtrl.baseNametableAddress) {
    //     0 => 0x23C0,
    //     1 => 0x27C0,
    //     2 => 0x2BC0,
    //     3 => 0x2FC0,
    // };
    // var attrTable: [64]u8 = undefined;
    // for (0..64) |i| {
    //     attrTable[i] = self.ppu_read(attrTableAddress + @as(u16, @intCast(i)));
    // }
    // const pvalues = [_]u8{0x3F, 0x06, 0x16, 0x26, 0x3F, 0x16, 0x26, 0x36, 0x3F,
    //                       0x01, 0x06, 0x16, 0x3F, 0x3F, 0x26, 0x16};
    // for (pvalues, 0..) |pv,i| {
    //     self.ppu_write(0x3f00 + @as(u16, @intCast(i)), pv);
    // }//hmm, bug...

    // const pa0: u16 = 0x3F00;
    // const pa1: u16 = 0x3F04;
    // const pa2: u16 = 0x3F08;
    // const pa3: u16 = 0x3F0C;
    // const parray = [_]u16{ pa0, pa1, pa2, pa3 };
    // _ = &parray;
    for (0..30) |row| {
        for (0..32) |col| {
            const tileIdx = self.nameTableAddress(@intCast(row), @intCast(col));
            const entry = self.ppu_read(tileIdx); //tileIdx
            const attrValue = self.getAttrValue2(row, col);

            const offset = @as(u16, 16) * entry + bgPatternTableAddr;
            var pixels: [16]u8 = .{0} ** 16;
            for (0..16) |i| {
                pixels[i] = self.ppu_read(offset + @as(u16, @intCast(i)));
            }
            const boo: u128 = @bitCast(pixels);
            for (0..8) |j| {
                for (0..8) |i| {
                    const k0: u7 = @truncate(8 * j + (i));
                    const k1: u7 = @truncate(8 * j + (i) + 64);
                    const b0 = (boo & (@as(u128, 1) << k0)) >> k0;
                    const b1 = (boo & (@as(u128, 1) << (k1))) >> (k1) << 1;
                    _ = &b1;
                    const res: u2 = @truncate((b0 | b1));
                    if (res != 0) {
                        const paletteIdx: PaletteIdx = .{
                            .tilePatternData = res,
                            .paletteNumFromAttr = attrValue,
                            .isSprite = false,
                        };
                        const colorIdx: u6 = @truncate(self.ppu_read(@as(u16, 0x3F00) + @as(u5, @bitCast(paletteIdx))));
                        // const colorIdx: u6 = @truncate(palette[res]);
                        // const colorIdx = palette[res];
                        // const colorIdx: u6 = @intCast(col+res);
                        // const colorIdx = pvalues[@as(u8,attrValue)*4 + @as(u8,res)];

                        // const colorIdx: u8 = 0;
                        const color = SystemPalette[colorIdx];
                        const tileOffset: usize = self.ppuScroll[1] % 8;
                        const tileXOffset: usize = self.ppuScroll[0] % 8;
                        var pos = (col * 8 +
                            (row * 8 + j) * 256 + (7 - i));
                        if (pos >= tileOffset * 256) {
                            pos -= tileOffset * 256;
                        }
                        if (pos >= tileXOffset) {
                            pos -= tileXOffset;
                        }
                        if (pos < self.outputBuffer.len) {
                            if ((@as(usize, col * 8) + 7 - 1 < 256) and
                                ((@as(usize, (row * 8)) + (j)) < 224))
                            {
                                self.outputBuffer[pos] = color; //rgba
                            }
                        }
                    }
                }
            }
        }
    }
    self.drawSprites();
    // self.drawBackgroundPalette();
    // self.drawPalette();
}
pub fn drawBackgroundPalette(self: *Ppu) void {
    for (0..16) |i| {
        const colorIdx: u6 = @truncate(self.ppu_read(@as(u16, 0x3F00) + @as(u16, @intCast(i))));
        const color = SystemPalette[colorIdx];
        for (0..16) |y| {
            for (0..16) |x| {
                const pos = i * 16 + x + y * 256 + 224 * 256;
                self.outputBuffer[pos] = color; //rgba
            }
        }
    }
}

pub fn drawPalette(self: *Ppu) void {
    for (0..4) |row| {
        for (0..16) |col| {
            for (0..16) |y| {
                for (0..16) |x| {
                    const color = SystemPalette[(row * 16 + col)];
                    // const a = (color & 0xFF000000) >> 6;
                    // const r = (color & 0x00FF0000) >> 4;
                    // const g = (color & 0x0000FF00) >> 2;
                    // const b = (color & 0x000000FF);
                    // const res =  (r << 4) + (g << 2) + b;
                    const pos = (row * 16 + y) * 256 + col * 16 + x;
                    self.outputBuffer[pos] = color;
                }
            }
        }
    }
}
pub fn drawSprites(self: *Ppu) void {
    // sprite.xPosition = 0
    const pa0: u16 = 0x3F10;
    const pa1: u16 = 0x3F14;
    const pa2: u16 = 0x3F18;
    const pa3: u16 = 0x3F1C;
    const spritePatternTableAddr: u16 = if (self.ppuCtrl.spriteSize == 0) switch (self.ppuCtrl.spritePatternTableAddress) {
        0 => 0x0000,
        1 => 0x1000,
    } else 0x0000;
    const parray = [_]u16{ pa0, pa1, pa2, pa3 };
    for (self.sprites) |sprite| {
        const offset = if (self.ppuCtrl.spriteSize == 0) 
              @as(u16, 16) * sprite.tileIdx + spritePatternTableAddr
            else brk: {
                const table = @as(u16, 0x1000) * (sprite.tileIdx & 0x1);
                const idx = sprite.tileIdx & 0xfe;
                break :brk @as(u16, 16) * idx + table;
            };
        var pixels: [16]u8 = .{0} ** 16;
        for (0..16) |i| {
            // if (offset + i < 2048) {
            pixels[i] = self.ppu_read(offset + @as(u16, @intCast(i)));
            // }
        }
        const paletteAddress: u16 = parray[sprite.attrs.palette];
        var palette: [4]u8 = undefined;
        for (0..4) |i| {
            palette[i] = self.ppu_read(paletteAddress + @as(u16, @intCast(i)));
        }
        // const zoo = std.StaticBitSet(128);

        const boo: u128 = @bitCast(pixels);
        // const px:[64]u2 = @bitCast(pixels);
        // if (foo.i > 120 ) {
        // std.debug.print("{any}\n", .{sprite});
        // std.debug.print("{any}\n\n\n", .{pixels});
        // // std.debug.print("{any}\n\n\n", .{px});
        //  @panic("yo");
        // }
        // const spriteSize:u8 = if (self.ppuCtrl.spriteSize == 1) 16 else 8;
        const spriteSize: u8 = 8;
        for (0..spriteSize) |j| {
            for (0..8) |i| {
                const k0: u7 = @truncate(spriteSize * j + (i));
                const k1: u7 = @truncate(spriteSize * j + (i) + 64);
                const b0 = (boo & (@as(u128, 1) << k0)) >> k0;
                const b1 = (boo & (@as(u128, 1) << (k1))) >> (k1) << 1;
                const res: u2 = @truncate(b0 | b1);
                // const palette: [4]u8 = .{ 0xff00000, 0xff, 160, 255 };
                // const _colors: [4]u32 = .{ 0xFF000000, 0xFF777777, 0xFFA0A0A0, 0xFFFFFFFF };
                if (res != 0) {
                    const colorIdx: u6 = @truncate(palette[res]);
                    const color = SystemPalette[colorIdx];
                    // const color = _colors[res];
                    const _x: usize = if (sprite.attrs.flipHorisontally) i else 7 - i;
                    const _y: usize = if (sprite.attrs.flipVertically) (7 - j) else j;
                    const pos = (@as(usize, sprite.xPosition) +
                        ((@as(usize, (sprite.yPosition)) + (_y)) * 256) + (_x));
                    // if (pos < self.outputBuffer.len) {
                    if ((@as(usize, sprite.xPosition) + _x < 256) and
                        ((@as(usize, (sprite.yPosition)) + (_y)) < 224))
                    {
                        if (sprite.attrs.behindBackground and self.outputBuffer[pos] != 0x000000) {
                        } else {
                          self.outputBuffer[pos] = color; //rgba
                        }
                    }
                }
            }
        }
    }
    if (self.ppuCtrl.spriteSize == 1) {
        for (self.sprites) |sprite| {
        const offset = if (self.ppuCtrl.spriteSize == 0) 
              @as(u16, 16) * sprite.tileIdx + spritePatternTableAddr
            else brk: {
                const table = @as(u16, 0x1000) * (sprite.tileIdx & 0x1);
                const idx = sprite.tileIdx & 0xfe;
                break :brk @as(u16, 16) * idx + table + 16;
            }; // + 4096;
            // const offset = @as(u16, 16) * sprite.tileIdx + 16 + spritePatternTableAddr; // + 4096;
            var pixels: [16]u8 = .{0} ** 16;
            for (0..16) |i| {
                // if (offset + i < 2048) {
                pixels[i] = self.ppu_read(offset + @as(u16, @intCast(i)));
                // }
            }
            const paletteAddress: u16 = parray[sprite.attrs.palette];
            var palette: [4]u8 = undefined;
            for (0..4) |i| {
                palette[i] = self.ppu_read(paletteAddress + @as(u16, @intCast(i)));
            }
            // const zoo = std.StaticBitSet(128);

            const boo: u128 = @bitCast(pixels);
            // const px:[64]u2 = @bitCast(pixels);
            // if (foo.i > 120 ) {
            // std.debug.print("{any}\n", .{sprite});
            // std.debug.print("{any}\n\n\n", .{pixels});
            // // std.debug.print("{any}\n\n\n", .{px});
            //  @panic("yo");
            // }
            // const spriteSize:u8 = if (self.ppuCtrl.spriteSize == 1) 16 else 8;
            const spriteSize: u8 = 8;
            for (0..spriteSize) |j| {
                for (0..8) |i| {
                    const k0: u7 = @truncate(spriteSize * j + (i));
                    const k1: u7 = @truncate(spriteSize * j + (i) + 64);
                    const b0 = (boo & (@as(u128, 1) << k0)) >> k0;
                    const b1 = (boo & (@as(u128, 1) << (k1))) >> (k1) << 1;
                    const res: u2 = @truncate(b0 | b1);
                    // const palette: [4]u8 = .{ 0xff00000, 0xff, 160, 255 };
                    // const _colors: [4]u32 = .{ 0xFF000000, 0xFF777777, 0xFFA0A0A0, 0xFFFFFFFF };
                    if (res != 0) {
                        const colorIdx: u6 = @truncate(palette[res]);
                        const color = SystemPalette[colorIdx];
                        // const color = _colors[res];
                        const _x: usize = if (sprite.attrs.flipHorisontally) i else 7 - i;
                        const _y: usize = if (sprite.attrs.flipVertically) (7 - j) else j;
                        const pos = (@as(usize, sprite.xPosition) +
                            ((@as(usize, (sprite.yPosition)) + (_y + 8)) * 256) + (_x));
                        if ((@as(usize, sprite.xPosition) + _x < 256) and
                            ((@as(usize, (sprite.yPosition)) + (_y + 8)) < 224))
                        {
                        if (sprite.attrs.behindBackground and self.outputBuffer[pos] != 0x000000) {
                        } else {
                            self.outputBuffer[pos] = color; //rgba
                        }
                        }
                    }
                }
            }
        }
    }
}
// const UnpackedPixel = struct {
//     x:u8,
//     color: u2
// };
// const dict: [64][8]u1 = brk: {
//     var d = std.mem.zeroes([64][8]u1);
//     for (0..8) |j| {
//         for (0..8) |i| {
//             d[j*8+i] = i%2 == 0;
//         }
//     }
//
//    break :brk d;
// };
// fn unpackChrByte(b0: u8, b1: u8) [8]u2 {
//     const a = dict[b0];
//     const b = dict[b1];
//     var res: [8]u2 = .{0}**8;
//     for (0..8) |i| {
//         res[i] = @as(u2, a[i]) + (@as(u2, b[i]) << 1);
//     }
//     return res;
// }

// Conceptually, the PPU does this 33 times for each scanline:
//
//     Fetch a nametable entry from $2000-$2FFF.
//     Fetch the corresponding attribute table entry from $23C0-$2FFF and increment the current VRAM address within the same row.
//     Fetch the low-order byte of an 8x1 pixel sliver of pattern table from $0000-$0FF7 or $1000-$1FF7.
//     Fetch the high-order byte of this sliver from an address 8 bytes higher.
//     Turn the attribute data and the pattern table data into palette indices, and combine them with data from sprite data using priority.
//
// It also does a fetch of a 34th (nametable, attribute, pattern) tuple that is never used, but some mappers rely on this fetch for timing purposes.
pub fn drawChrData(self: *Ppu) void {
    _ = &self;
    var _sprites: [16 * 16]Sprite = .{Sprite{}} ** (16 * 16); // 2048?
    for (0..16) |i| {
        for (0..16) |j| {
            _sprites[16 * i + j].tileIdx = @truncate(16 * i + j);
            _sprites[16 * i + j].xPosition = @truncate(j * 8);
            _sprites[16 * i + j].yPosition = @as(u8, @truncate(i * 8));
        }
    }
    // sprite.xPosition = 0
    // colors going to be B/W for now
    for (&_sprites) |*sprite| {
        const offset = @as(u16, 16) * sprite.tileIdx; // + 4096;
        var pixels: [16]u8 = .{0} ** 16;
        for (0..16) |i| {
            // if (offset + i < 2048) {
            pixels[i] = self.ppu_read(offset + @as(u16, @intCast(i)));
            // }
        }
        // const zoo = std.StaticBitSet(128);

        const boo: u128 = @bitCast(pixels);
        // const px:[64]u2 = @bitCast(pixels);
        // if (foo.i > 120 ) {
        // std.debug.print("{any}\n", .{sprite});
        // std.debug.print("{any}\n\n\n", .{pixels});
        // // std.debug.print("{any}\n\n\n", .{px});
        //  @panic("yo");
        // }
        for (0..8) |j| {
            for (0..8) |i| {
                const k0: u7 = @truncate(8 * j + (i));
                const k1: u7 = @truncate(8 * j + (i) + 64);
                const b0 = (boo & (@as(u128, 1) << k0)) >> k0;
                const b1 = (boo & (@as(u128, 1) << (k1))) >> (k1) << 1;
                const res: u2 = @truncate(b0 | b1);
                // const palette: [4]u8 = .{ 0xff00000, 0xff, 160, 255 };
                const _colors: [4]u32 = .{ 0xFF000000, 0xFF777777, 0xFFA0A0A0, 0xFFFFFFFF };
                if (res != 0) {
                    const color = _colors[res];
                    const pos = (@as(usize, sprite.xPosition) +
                        ((@as(usize, (sprite.yPosition)) + (j)) * 256) + (7 - i));
                    // if (pos < self.outputBuffer.len) {
                    self.outputBuffer[pos] = color; //rgba
                    // }

                }
            }
        }
        // for (px, 0..)|row,j| {
        //     for (row, 0..)|p, i| {
        //         if (p != 0) {
        //             const pos = 4*(sprite.xPosition +
        //                    (sprite.yPosition*240)+i+(8*j));
        //             self.outputBuffer[pos] = 255;//rgba
        //             self.outputBuffer[pos+1] = 255;//rgba
        //             self.outputBuffer[pos+2] = 255;//rgba
        //             self.outputBuffer[pos+3] = 255;//rgba
        //         }
        //
        //     }
        // }
        // outputBuffer: []u8, // always 256x240x4
        // sprite.xPosition
        // sprite.yPosition
        // sprite.attrs.palette
    }
}
