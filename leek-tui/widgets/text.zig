pub const root = @import("../root.zig");
pub const Buffer = @import("../buffer.zig").Buffer;
pub const termy = root.termy;
pub const stdx = root.stdx; 
const std = @import("std");

pub const Text = struct {
    pub const Span = struct{
        start: u16,
        end: u16,
        fg: ?termy.Style.Color = null,
        bg: ?termy.Style.Color = null,
        uc: ?termy.Style.Color = null,
        mods: ?root.tui.Modifier = null,
    };

    spans: ?[]const Span = null,
    text: []const u8,
    
    pub fn render(self: *const Text, allocator: std.mem.Allocator, buffer: *Buffer, area: root.Rect) !void{
        var iter: stdx.unicode.segmentation.GraphemeIterator = .init(self.text);
        var pos: usize = 0;
        while(iter.next() catch |err| { stdx.err = "Failed to find next grapheme"; return err; })|grapheme|{
            _ = buffer.get(@intCast(area.x+pos), area.y).setSymbol(grapheme, allocator);
            pos+=stdx.unicode.width.graphemeWidth(grapheme, false) catch |err| { stdx.err = "Failed to get grapheme size"; return err; };
        }
        if(self.spans)|spans|{
            for(spans)|span|{
                for(span.start..span.end)|x|{
                    var cell = buffer.get(@intCast(area.x+x), area.y);
                    if(span.fg)|fg|
                        _ = cell.setFg(fg);
                    if(span.uc)|uc|
                        _ = cell.setUc(uc);
                    if(span.bg)|bg|
                        _ = cell.setBg(bg);
                    if(span.mods)|mods|
                        _ = cell.setMod(mods);
                }
            }
        }
    }
};
