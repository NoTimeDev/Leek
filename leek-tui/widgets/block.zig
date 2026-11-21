pub const root = @import("../root.zig");
pub const Buffer = @import("../buffer.zig").Buffer;
pub const termy = root.termy;
pub const stdx = root.stdx;

pub const BorderStyle = enum {
    Rounded,
    Plain,
};

pub const BorderPositions = packed struct(u8) {
    Top: bool = false,
    Bottom: bool = false,
    Left: bool = false,
    Right: bool = false,
    _: u4 = 0,
};

pub const Block = struct {
    style: BorderStyle,
    positions: BorderPositions,
    fg: termy.Style.Color,
    bg: termy.Style.Color,

    pub fn render(self: *Block, buffer: *Buffer, area: root.Rect) Block {
        _ = self;
        _ = buffer;
        _ = area;
    }
};
