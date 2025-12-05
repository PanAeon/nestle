const std = @import("std");

const Cpu = @import("Cpu.zig");
const Mapper = @import("../mapper/Mapper.zig");
const MemoryController = @import("MemoryController.zig");

// there are exactly three PPU ticks per CPU cycle,
const Ppu = @This();

const SpriteAttrs = packed struct {
    palette: u2 = 0, //  Palette (4 to 7) of sprite
    _: u3 = 0,
    behindBackground: bool = false, // 0 - in front of bck, 1 - behind
    flipHorisontally: bool = false,
    flipVertically: bool = false,
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
    enableBackgroundRendering: bool = false,
    enableSpriteRendering: bool = false,
    emphasizeRed: bool = false, // green on PAL/Dendy
    emphasizeGreen: bool = false,
    empahsizeBlue: bool = false,
};
// PPUSTATUS - Rendering events ($2002 read)
const PPUStatus = packed struct {
    identifier: u5 = 0, //(PPU open bus or 2C05 PPU identifier)
    spriteOverflow: bool = false,
    sprite0Hit: bool = false,
    VBlank: bool = false, // Vblank flag, cleared on read. Unreliable
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
ppuScroll: [2]u8 = .{ 0, 0 }, // Wx2 x scroll then y scroll ... (x is high byte)
ppuAddr: u16 = 0, // Wx2 msb,lsb
ppuData: u8 = 0, // RW
oamDma: u8 = 0, // Write
//
// internal registers:
vramIdx: u15 = 0, // current VRam index
tmpVramIdx: u15 = 0, // temporary VRam index
fineXScroll: u3 = 0, //(x) fine x scroll
writeToggle: u1 = 0, // first or second write toggle
sprites: [64]Sprite = .{Sprite{}}**64,
currentSprites: [8]Sprite = .{Sprite{}}**8,
mapper: Mapper,
palette: [32]u8 = .{0}**32,
outputBuffer: []u32, // always 256x240x4
//
// t,v:
// yyy NN YYYYY XXXXX
// ||| || ||||| +++++-- coarse X scroll
// ||| || +++++-------- coarse Y scroll
// ||| ++-------------- nametable select
// +++----------------- fine Y scroll

cpu: *Cpu = undefined,
memoryController: *MemoryController = undefined,

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
            return self.ppu_read(self.ppuAddr);
        }, // R/W Vram data
        else => std.debug.panic("wrong address 0x{x} for PPU", .{addr}),
    }
}

pub fn write(self: *Ppu, addr: u16, data: u8) void {
    switch (addr) {
        0x2000 => {
            self.ppuCtrl = @bitCast(data);
            // std.debug.print("PPU: write to CTRL, {any}\n", .{self.ppuCtrl});
        }, // TODO: writes to this register are ignored until the first pre-render scanline.
        0x2001 => self.ppuMask = @bitCast(data), // w
        0x2002 => {}, // ??
        0x2003 => self.oamAddr = data,
        0x2004 => {
            const bytes: []u8 = @ptrCast(&self.sprites);
            bytes[self.oamAddr] = data;
            self.oamAddr +%= 1;
        }, //OAM R/W
        0x2005 => {
            self.ppuScroll[self.writeToggle] = data;
            self.writeToggle +%= 1;
        }, // Wx2
        0x2006 => {
            if (self.writeToggle == 0) {
                // high byte first
                self.ppuAddr &= 0xFF;
                self.ppuAddr |= @as(u16, data) * 256;
                self.ppuAddr &= 0x3fff; // clear top two bits
            } else {
                self.ppuAddr &= (0xFF << 8);
                self.ppuAddr |= @as(u16, data);
            }
            self.writeToggle +%= 1;
        }, // Wx2
        0x2007 => { //PPUDATA - VRAM data
            self.ppu_write(self.ppuAddr, data);
            const incr = self.ppuCtrl.vramAddressIncrement;
            self.ppuAddr +%= (~incr + (incr * @as(u16, 32)));
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
                const res =  self.mapper.ppu_read(_addr);
    // if (addr >= 3*16 and addr < 4*16) {
    // std.debug.print("ppu read: 0x{x}, data: 0x{x}\n", .{addr, res});
    // }
            return res;
        },
        0x3F00...0x3F1F => return self.palette[addr-0x3f00], // palette ram indexes
        0x3F20...0x3FFF => return self.palette[(addr-0x3f20)%32], // mirrors of 0x3F00-0x3F1F
    }
}
pub fn ppu_write(self: *Ppu, addr: u16, data: u8) void {
    const _addr: u14 = @truncate(addr);
    // if (addr >= 3*16 and addr < 4*16) {
    // std.debug.print("ppu write: 0x{x}, data: 0x{x}\n", .{addr, data});
    // }
    switch (_addr) {
        0x0000...0x3EFF => self.mapper.ppu_write(_addr, data),
        0x3F00...0x3F1F => self.palette[addr - 0x3f00] = data, // palette ram indexes
        0x3F20...0x3FFF => self.palette[(addr-0x3f20)%32] = data, // mirrors of 0x3F00-0x3F1F
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
// FIXME: add 513/514 cycles somehow
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
    // takes 513/514 cycles..
}
// run single instruction ...
pub fn run(self: *Ppu) void {
    _ = &self;
}
// see https://github.com/lukexor/tetanes/blob/main/tetanes-core/src/video.rs
// for actual palette generation code
// argb?
const NTSCPalette = [512]u32 { 0xFF000000, 0xFF000016, 0xFF040235, 0xFF01004B, 0xFF07046A, 0xFF050180, 0xFF0B069F, 0xFF0903B5, 0xFF1A0003, 0xFF200521, 0xFF1E0237, 0xFF240756, 0xFF22046C, 0xFF28098B, 0xFF2506A1, 0xFF2B0BC0, 0xFF3D080D, 0xFF3B0524, 0xFF400A42, 0xFF3E0759, 0xFF440C77, 0xFF42098D, 0xFF480EAC, 0xFF450BC2, 0xFF570910, 0xFF550526, 0xFF5B0A45, 0xFF59075B, 0xFF5E0C7A, 0xFF5C0990, 0xFF620EAF, 0xFF600BC5, 0xFF720913, 0xFF770E31, 0xFF750B48, 0xFF7B1066, 0xFF790C7C, 0xFF7F119B, 0xFF7C0EB1, 0xFF8213D0, 0xFF94111E, 0xFF920E34, 0xFF981352, 0xFF951069, 0xFF9B1587, 0xFF99129E, 0xFF9F17BC, 0xFF9D13D2, 0xFFAE1120, 0xFFAC0E36, 0xFFB21355, 0xFFB0106B, 0xFFB6158A, 0xFFB312A0, 0xFFB917BF, 0xFFB714D5, 0xFFC91123, 0xFFCF1641, 0xFFCC1358, 0xFFD21876, 0xFFD0158C, 0xFFD61AAB, 0xFFD417C1, 0xFFDA1CE0, 0xFF092408, 0xFF07211E, 0xFF0D263D, 0xFF0A2353, 0xFF102872, 0xFF0E2588, 0xFF142AA7, 0xFF1127BD, 0xFF23240B, 0xFF212121, 0xFF27263F, 0xFF252356, 0xFF2A2874, 0xFF28258B, 0xFF2E2AA9, 0xFF2C27BF, 0xFF3E240D, 0xFF43292C, 0xFF412642, 0xFF472B61, 0xFF452877, 0xFF4B2D95, 0xFF482AAC, 0xFF4E2FCA, 0xFF602C18, 0xFF5E292E, 0xFF642E4D, 0xFF612B63, 0xFF673082, 0xFF652D98, 0xFF6B32B7, 0xFF692FCD, 0xFF7A2D1B, 0xFF782931, 0xFF7E2E50, 0xFF7C2B66, 0xFF823084, 0xFF7F2D9B, 0xFF8532B9, 0xFF832FD0, 0xFF952D1D, 0xFF9B323C, 0xFF982F52, 0xFF9E3471, 0xFF9C3087, 0xFFA236A6, 0xFFA032BC, 0xFFA637DA, 0xFFB73528, 0xFFB5323E, 0xFFBB375D, 0xFFB93473, 0xFFBF3992, 0xFFBC36A8, 0xFFC23BC7, 0xFFC038DD, 0xFFD2352B, 0xFFCF3241, 0xFFD53760, 0xFFD33476, 0xFFD93994, 0xFFD736AB, 0xFFDC3BC9, 0xFFDA38E0, 0xFF0A4008, 0xFF0F4526, 0xFF0D423D, 0xFF13475B, 0xFF114471, 0xFF174990, 0xFF1445A6, 0xFF1A4AC5, 0xFF2C4813, 0xFF2A4529, 0xFF304A47, 0xFF2D475E, 0xFF334C7C, 0xFF314993, 0xFF2F46A9, 0xFF354BC7, 0xFF464815, 0xFF44452B, 0xFF4A4A4A, 0xFF484760, 0xFF4E4C7F, 0xFF4B4995, 0xFF514EB4, 0xFF4F4BCA, 0xFF614818, 0xFF674D36, 0xFF644A4D, 0xFF6A4F6B, 0xFF684C81, 0xFF6E51A0, 0xFF6C4EB6, 0xFF7253D5, 0xFF835123, 0xFF814D39, 0xFF875257, 0xFF854F6E, 0xFF8B548C, 0xFF8851A3, 0xFF864EB9, 0xFF8C53D7, 0xFF9E5125, 0xFF9B4D3C, 0xFFA1535A, 0xFF9F4F70, 0xFFA5548F, 0xFFA351A5, 0xFFA856C4, 0xFFA653DA, 0xFFB85128, 0xFFBE5646, 0xFFBC535D, 0xFFC1587B, 0xFFBF5592, 0xFFC55AB0, 0xFFC356C6, 0xFFC95CE5, 0xFFDA5933, 0xFFD85649, 0xFFDE5B68, 0xFFDC587E, 0xFFD95594, 0xFFDF5AB3, 0xFFDD57C9, 0xFFE35CE8, 0xFF126410, 0xFF106126, 0xFF166645, 0xFF14625B, 0xFF1A6779, 0xFF176490, 0xFF1D69AE, 0xFF1B66C5, 0xFF2D6412, 0xFF336931, 0xFF306647, 0xFF366B66, 0xFF34687C, 0xFF3A6D9B, 0xFF3869B1, 0xFF3E6FCF, 0xFF476415, 0xFF4D6933, 0xFF4B664A, 0xFF516B68, 0xFF4E687F, 0xFF546D9D, 0xFF526AB3, 0xFF586FD2, 0xFF6A6C20, 0xFF676936, 0xFF6D6E55, 0xFF6B6B6B, 0xFF717089, 0xFF6F6DA0, 0xFF7472BE, 0xFF726FD5, 0xFF846C22, 0xFF8A7141, 0xFF886E57, 0xFF8D7376, 0xFF8B708C, 0xFF9175AB, 0xFF8F72C1, 0xFF9577DF, 0xFF9E6C25, 0xFFA47144, 0xFFA26E5A, 0xFFA87378, 0xFFA6708F, 0xFFAB75AD, 0xFFA972C4, 0xFFAF77E2, 0xFFC17530, 0xFFBE7246, 0xFFC47765, 0xFFC2737B, 0xFFC8799A, 0xFFC675B0, 0xFFCC7ACE, 0xFFC977E5, 0xFFDB7532, 0xFFE17A51, 0xFFDF7767, 0xFFE57C86, 0xFFE2799C, 0xFFE87EBB, 0xFFE67BD1, 0xFFEC80F0, 0xFF137F0F, 0xFF19842E, 0xFF178144, 0xFF1D8663, 0xFF1A8379, 0xFF208898, 0xFF1E85AE, 0xFF248ACD, 0xFF36881A, 0xFF338531, 0xFF398A4F, 0xFF378665, 0xFF3D8C84, 0xFF3B889A, 0xFF418DB9, 0xFF3E8ACF, 0xFF50881D, 0xFF568D3B, 0xFF548A52, 0xFF598F70, 0xFF578C87, 0xFF5D91A5, 0xFF5B8EBB, 0xFF6193DA, 0xFF6A8820, 0xFF708D3E, 0xFF6E8A54, 0xFF748F73, 0xFF728C89, 0xFF7791A8, 0xFF758EBE, 0xFF7B93DD, 0xFF8D902A, 0xFF8B8D41, 0xFF90925F, 0xFF8E8F76, 0xFF949494, 0xFF9291AA, 0xFF9896C9, 0xFF9593DF, 0xFFA7902D, 0xFFAD954C, 0xFFAB9262, 0xFFB19780, 0xFFAE9497, 0xFFB499B5, 0xFFB296CC, 0xFFB89BEA, 0xFFC19030, 0xFFC7964E, 0xFFC59264, 0xFFCB9783, 0xFFC99499, 0xFFCF99B8, 0xFFCC96CE, 0xFFD29BED, 0xFFE4993A, 0xFFE29651, 0xFFE89B6F, 0xFFE59886, 0xFFEB9DA4, 0xFFE999BA, 0xFFEF9ED9, 0xFFED9BEF, 0xFF1CA317, 0xFF22A836, 0xFF20A54C, 0xFF26AA6B, 0xFF23A781, 0xFF29ACA0, 0xFF27A9B6, 0xFF25A6CC, 0xFF36A31A, 0xFF3CA939, 0xFF3AA54F, 0xFF40AA6D, 0xFF3EA784, 0xFF43ACA2, 0xFF41A9B9, 0xFF47AED7, 0xFF59AC25, 0xFF57A93B, 0xFF5CAE5A, 0xFF5AAB70, 0xFF60B08F, 0xFF5EACA5, 0xFF64B2C3, 0xFF61AEDA, 0xFF73AC28, 0xFF79B146, 0xFF77AE5C, 0xFF7DB37B, 0xFF7AB091, 0xFF78ADA8, 0xFF7EB2C6, 0xFF7CAEDC, 0xFF8DAC2A, 0xFF93B149, 0xFF91AE5F, 0xFF97B37E, 0xFF95B094, 0xFF9BB5B2, 0xFF98B2C9, 0xFF9EB7E7, 0xFFB0B435, 0xFFAEB14B, 0xFFB4B66A, 0xFFB1B380, 0xFFB7B89F, 0xFFB5B5B5, 0xFFBBBAD4, 0xFFB9B7EA, 0xFFCAB438, 0xFFD0B956, 0xFFCEB66C, 0xFFD4BB8B, 0xFFD2B8A1, 0xFFCFB5B8, 0xFFD5BAD6, 0xFFD3B7EC, 0xFFE5B53A, 0xFFEBBA59, 0xFFE8B66F, 0xFFEEBB8E, 0xFFECB8A4, 0xFFF2BDC2, 0xFFF0BAD9, 0xFFF5BFF7, 0xFF25C71F, 0xFF23C436, 0xFF28C954, 0xFF26C66B, 0xFF2CCB89, 0xFF2AC89F, 0xFF30CDBE, 0xFF2DCAD4, 0xFF3FC722, 0xFF3DC438, 0xFF43C957, 0xFF40C66D, 0xFF46CB8C, 0xFF44C8A2, 0xFF4ACDC1, 0xFF48CAD7, 0xFF59C825, 0xFF5FCD43, 0xFF5DC959, 0xFF63CF78, 0xFF61CB8E, 0xFF67D0AD, 0xFF64CDC3, 0xFF6AD2E2, 0xFF7CD02F, 0xFF7ACD46, 0xFF80D264, 0xFF7DCF7B, 0xFF83D499, 0xFF81D1AF, 0xFF87D6CE, 0xFF85D2E4, 0xFF96D032, 0xFF94CD48, 0xFF9AD267, 0xFF98CF7D, 0xFF9ED49C, 0xFF9BD1B2, 0xFFA1D6D1, 0xFF9FD3E7, 0xFFB1D035, 0xFFB7D553, 0xFFB4D26A, 0xFFBAD788, 0xFFB8D49E, 0xFFBED9BD, 0xFFBCD6D3, 0xFFC1DBF2, 0xFFD3D840, 0xFFD1D556, 0xFFD7DA74, 0xFFD5D78B, 0xFFDADCA9, 0xFFD8D9C0, 0xFFDEDEDE, 0xFFDCDBF4, 0xFFEED842, 0xFFEBD558, 0xFFF1DA77, 0xFFEFD78D, 0xFFF5DCAC, 0xFFF2D9C2, 0xFFF8DEE1, 0xFFF6DBF7, 0xFF25E31F, 0xFF2BE83E, 0xFF29E554, 0xFF2FEA73, 0xFF2DE789, 0xFF33ECA7, 0xFF30E9BE, 0xFF36EEDC, 0xFF48EB2A, 0xFF46E840, 0xFF4CED5F, 0xFF49EA75, 0xFF4FEF94, 0xFF4DECAA, 0xFF53F1C9, 0xFF51EEDF, 0xFF62EC2D, 0xFF60E843, 0xFF66ED61, 0xFF64EA78, 0xFF6AEF96, 0xFF67ECAD, 0xFF6DF1CB, 0xFF6BEEE1, 0xFF7DEC2F, 0xFF83F14E, 0xFF80EE64, 0xFF86F383, 0xFF84EF99, 0xFF8AF4B7, 0xFF88F1CE, 0xFF8DF6EC, 0xFF9FF43A, 0xFF9DF150, 0xFFA3F66F, 0xFFA1F385, 0xFFA6F8A4, 0xFFA4F5BA, 0xFFAAFAD9, 0xFFA8F6EF, 0xFFBAF43D, 0xFFB7F153, 0xFFBDF672, 0xFFBBF388, 0xFFC1F8A6, 0xFFBFF5BD, 0xFFC4FADB, 0xFFC2F7F2, 0xFFD4F43F, 0xFFDAF95E, 0xFFD7F674, 0xFFDDFB93, 0xFFDBF8A9, 0xFFE1FDC8, 0xFFDFFADE, 0xFFE5FFFC, 0xFFF6FC4A, 0xFFF4F960, 0xFFFAFE7F, 0xFFF8FB95, 0xFFFEFFB4, 0xFFFBFDCA, 0xFFFFFFE9, 0xFFFFFFFF };
const SystemPalette =  [64]u32 {
        // 0x00
        (0xFF545454), (0xFF001E74), (0xFF081090), (0xFF300088), // $00-$03
        (0xFF440064), (0xFF5C0030), (0xFF540400), (0xFF3C1800), // $04-$07
        (0xFF202A00), (0xFF083A00), (0xFF004000), (0xFF003C00), // $08-$0B
        (0xFF00323C), (0xFF000000), (0xFF000000), (0xFF000000), // $0C-$0F
        // 0xFF10
        (0xFF989698), (0xFF084CC4), (0xFF3032EC), (0xFF5C1EE4), // $10-$13
        (0xFF8814B0), (0xFFA01464), (0xFF982220), (0xFF783C00), // $14-$17
        (0xFF545A00), (0xFF287200), (0xFF087C00), (0xFF007628), // $18-$1B
        (0xFF006678), (0xFF000000), (0xFF000000), (0xFF000000), // $1C-$1F
        // 0xFF20
        (0xFFECEEEC), (0xFF4C9AEC), (0xFF787CEC), (0xFFB062EC), // $20-$23
        (0xFFE454EC), (0xFFEC58B4), (0xFFEC6A64), (0xFFD48820), // $24-$27
        (0xFFA0AA00), (0xFF74C400), (0xFF4CD020), (0xFF38CC6C), // $28-$2B
        (0xFF38B4CC), (0xFF3C3C3C), (0xFF000000), (0xFF000000), // $2C-$2F
        // 0xFF30
        (0xFFECEEEC), (0xFFA8CCEC), (0xFFBCBCEC), (0xFFD4B2EC), // $30-$33
        (0xFFECAEEC), (0xFFECAED4), (0xFFECB4B0), (0xFFE4C490), // $34-$37
        (0xFFCCD278), (0xFFB4DE78), (0xFFA8E290), (0xFF98E2B4), // $38-$3B
        (0xFFA0D6E4), (0xFFA0A2A0), (0xFF000000), (0xFF000000), // $3C-$3F
    };

// Backgrounds and sprites each have 4 palettes of 4 colors, located at $3F00-$3F1F in VRAM
// draw entire frame for simplicity
pub fn drawFrame(self: *Ppu) void {
    const bgPatternTableAddr:u16 = switch (self.ppuCtrl.backgroundPatternTableAddress) {
        0 => 0x0000,
        1 => 0x1000
    };
    const nametableAddress:u16 = switch (self.ppuCtrl.baseNametableAddress) {
        0 => 0x2000,
        1 => 0x2400,
        2 => 0x2800,
        3 => 0x2C00
    };
    const p0:u6 = @truncate(self.ppu_read(0x3F00));
    const p1:u6 = @truncate(self.ppu_read(0x3F00+1));
    const p2:u6 = @truncate(self.ppu_read(0x3F00+2));
    const p3:u6 = @truncate(self.ppu_read(0x3F00+3));
    const parray  = [_]u6{p0,p1,p2,p3};
    _ = &parray;
    for (0..30) |row| {
        for (0..32) |col| {
            const entry = self.ppu_read(@as(u16, @truncate(nametableAddress + row*32 + col))); //tileIdx
            const attrs = self.ppu_read(@as(u16, @truncate(0x23c0 + row*32 + col)));
            _ = &attrs;
            const offset = @as(u16, 16) * entry + bgPatternTableAddr;
            var pixels : [16]u8 = .{0}**16;
            for (0..16) |i| {
                   pixels[i]  = self.ppu_read(offset + @as(u16, @intCast(i))); 
            }
             const boo:u128 = @bitCast(pixels);
    for (0..8) |j| {
        for (0..8) |i| {
            const k0:u7 = @truncate(8*j + (i));
            const k1:u7 = @truncate(8*j + (i) + 64);
            const b0 = (boo & (@as(u128,1) << k0)) >> k0;
            const b1 = (boo & (@as(u128, 1) << (k1))) >> (k1) << 1;
            const res:u2 = @truncate(b0 | b1);
            const palette: [4]u32 = .{0xFF000000, 0xFF777777, 0xFFA0A0A0, 0xFFFFFFFF};
            _ = &palette;
            if (res != 0) {
                    // const color = palette[res];
                    const colorIdx:u8 = parray[res];
                    const color = SystemPalette[colorIdx];
                    const pos = ( col*8 + 
                           (row*8 + j)*256 + (7-i));
                    if (pos < self.outputBuffer.len) {
                    self.outputBuffer[pos] = color;//rgba
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
    var _sprites : [16*16]Sprite = .{Sprite{}}**(16*16); // 2048?
    for (0..16)|i| {
        for(0..16)|j| {
          _sprites[16*i+j].tileIdx = @truncate(16*i+j);
          _sprites[16*i+j].xPosition = @truncate(j*8);
          _sprites[16*i+j].yPosition = @as(u8, @truncate( i*8));
        }
    }
     // sprite.xPosition = 0
    // colors going to be B/W for now
    for (&_sprites) |*sprite| {
        const offset = @as(u16, 16) * sprite.tileIdx; // + 4096;
        var pixels : [16]u8 = .{0}**16;
        for (0..16) |i| {
            // if (offset + i < 2048) {
               pixels[i]  = self.ppu_read(offset + @as(u16, @intCast(i))); 
            // }
        }
        // const zoo = std.StaticBitSet(128);
        
         const boo:u128 = @bitCast(pixels);
        // const px:[64]u2 = @bitCast(pixels);
    // if (foo.i > 120 ) {
    // std.debug.print("{any}\n", .{sprite});
    // std.debug.print("{any}\n\n\n", .{pixels});
    // // std.debug.print("{any}\n\n\n", .{px});
    //  @panic("yo");
    // }
    for (0..8) |j| {
        for (0..8) |i| {
            const k0:u7 = @truncate(8*j + (i));
            const k1:u7 = @truncate(8*j + (i) + 64);
            const b0 = (boo & (@as(u128,1) << k0)) >> k0;
            const b1 = (boo & (@as(u128, 1) << (k1))) >> (k1) << 1;
            const res:u2 = @truncate(b0 | b1);
            const palette: [4]u8 = .{0, 96, 160, 255};
            if (res != 0) {
                    const color = palette[res];
                    const pos = 4*(@as(usize, sprite.xPosition) +
                           ((@as(usize, (sprite.yPosition)) + (j))*256)+(7-i));
                    // if (pos < self.outputBuffer.len) {
                    self.outputBuffer[pos] = color;//rgba
                    self.outputBuffer[pos+1] = color;//rgba
                    self.outputBuffer[pos+2] = color;//rgba
                    self.outputBuffer[pos+3] = 255;//rgba
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
