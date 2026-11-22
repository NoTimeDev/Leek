pub const root = @import("../root.zig");
pub const Buffer = @import("../buffer.zig").Buffer;
pub const termy = root.termy;
pub const stdx = root.stdx; 
const std = @import("std");

pub const BorderStyle = struct {
    // Horizontal + Vertical
    tab: u21,
    lar: u21,

    // Top-left, Top-right, Bottom-left, Bottom-right
    tlc: u21,
    trc: u21,
    blc: u21,
    brc: u21,

    pub const Plain: BorderStyle = .{
        .tab = '─',
        .lar = '│',

        .tlc = '┌',
        .trc = '┐',
        .blc = '└',
        .brc = '┘',
    };

    pub const Rounded: BorderStyle = .{
        .tab = '─',
        .lar = '│',

        .tlc = '╭',
        .trc = '╮',
        .blc = '╰',
        .brc = '╯',
    };

    pub const Retro: BorderStyle = .{
        .tab = '-',
        .lar = '|',

        .tlc = '+',
        .trc = '+',
        .blc = '+',
        .brc = '+',
    };
};

pub const BorderPositions = packed struct(u8) {
    Top: bool = false,
    Bottom: bool = false,
    Left: bool = false,
    Right: bool = false,
    _: u4 = 0,

    pub const ALL: BorderPositions = .{
        .Top = true,
        .Bottom = true,
        .Left = true,
        .Right = true,
    };
};

pub const Block = struct {
    style: BorderStyle = .Plain,
    positions: BorderPositions = .{},
    fg: termy.Style.Color = .Reset,
    bg: termy.Style.Color = .Reset,

    /// Returns the inner rect of a block 
    pub fn inner(self: *const Block) root.Rect{
        _ = self;
        return .{
            .height = 0,
            .width = 0,
            .x = 0,
            .y = 0,
        };
    }
 
    pub fn render(self: *const Block, allocator: std.mem.Allocator, buffer: *Buffer, area: root.Rect) !void {
        for(area.x..area.x+area.width)|x|{
            if(self.positions.Top)
                _ = buffer.get(@intCast(x), area.y).setFg(self.fg).setSymbolFromChar(self.style.tab, allocator);
            if(self.positions.Bottom)
                _ = buffer.get(@intCast(x), area.y+area.height).setFg(self.fg).setSymbolFromChar(self.style.tab, allocator);
        }

        for(area.y..area.y+area.height)|y|{
            if(self.positions.Left)
                _ = buffer.get(area.x, @intCast(y)).setFg(self.fg).setSymbolFromChar(self.style.lar, allocator);
            if(self.positions.Right)
                _ = buffer.get(area.x+area.width, @intCast(y)).setFg(self.fg).setSymbolFromChar(self.style.lar, allocator);
        }

        if(self.positions.Top and self.positions.Left)
            _ = buffer.get(area.x, area.y).setFg(self.fg).setSymbolFromChar(self.style.tlc, allocator);
    
        if(self.positions.Top and self.positions.Right)
            _ = buffer.get(area.x+area.width, area.y).setFg(self.fg).setSymbolFromChar(self.style.trc, allocator);
    
        if(self.positions.Bottom and self.positions.Left)
            _ = buffer.get(area.x, area.y+area.height).setFg(self.fg).setSymbolFromChar(self.style.blc, allocator);
    
        if(self.positions.Bottom and self.positions.Right)
            _ = buffer.get(area.x+area.width, area.y+area.height).setFg(self.fg).setSymbolFromChar(self.style.brc, allocator);
    
    }
};
