const segmentation = @import("segmentation.zig");
const table = @import("table.zig");
const std = @import("std");

pub fn graphemeStrWidth(str: []const u8, comptime cjk: bool) !usize {
    var total: usize = 0;
    var iter: segmentation.GraphemeIterator = .init(str);
    while (try iter.next()) |g| {
        total += try graphemeWidth(g, cjk);
    }
    return total;
}

pub fn graphemeWidth(grapheme: []const u8, comptime cjk: bool) !u2 {
    var iter: std.unicode.Utf8Iterator = (try std.unicode.Utf8View.init(grapheme)).iterator();
    while (iter.nextCodepoint()) |cp| {
        const w = codePointWidth(cp, cjk);
        if (w != 0) {
            if (iter.nextCodepoint()) |ncp| {
                if (0x1F3FB <= ncp and ncp <= 0x1F3FF) return 2;
                if (ncp == 0xFE0E) return 1;
                if (ncp == 0xFE0F) return 2;
            }
            return w;
        }
    }
    return 1;
}

/// Detects the width of a codepoint
/// Stuff like delete and non printable characters are zero
/// Techincally characters can be 3 cells but it is not allowed by this function
///
/// Note: It is always better to use `graphemeWidth` unless you NEED the width of a codepoint
pub fn codePointWidth(cp: u21, comptime cjk: bool) u2 {
    if ((cp >= 0x0000 and cp <= 0x001F) or (cp >= 0x007F and cp <= 0x009F)) {
        return 0;
    } else if ((cp >= 0x1160 and cp <= 0x11FF) or (cp >= 0x2060 and cp <= 0x206F) or
        (cp >= 0xFFF0 and cp <= 0xFFF8) or (cp >= 0xE0000 and cp <= 0xE0FFF))
    {
        return 0;
    } else if ((cp >= 0x3400 and cp <= 0x4DBF) or (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0x20000 and cp <= 0x2FFFD) or
        (cp >= 0x30000 and cp <= 0x3FFFD))
    {
        return 2;
    } else {
        const cat = table.getGraphemeCat(cp);
        if (cat == .Regional_Indicator) {
            return 2;
        }
        if (cat == .ZWJ) {
            return 0;
        }

        if (table.isMeMn(cp)) {
            return 0;
        }
    }

    return switch (table.getWidth(cp) orelse return 1) {
        .N, .H, .Na => 1,
        .W, .F => 2,
        .A => if (cjk) 2 else 1,
    };
}

test {
    std.testing.refAllDecls(@This());
}
