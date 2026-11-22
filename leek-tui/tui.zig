const termy = @import("root.zig").termy;
const stdx = @import("root.zig").stdx;
const std = @import("std");
const buffer = @import("buffer.zig");

pub const Rect = @import("root.zig").Rect;
pub const Modifier = buffer.Modifier;

pub const Tui = struct {
    tty: *termy.Tty,
    cursor: termy.Cursor,
    style: termy.Style,
    terminal: termy.Terminal,
    allocator: std.mem.Allocator,
    size: Rect,
    buffer: [2]buffer.Buffer,
    curbuffer: u1 = 0,

    pub fn init(tty: *termy.Tty, allocator: std.mem.Allocator) !Tui {
        var terminal: termy.Terminal = .init(tty);

        stdx.err = "Failed to set up tui";
        const eh = termy.Terminal.Enhancements;
        try terminal.enableCp();
        try terminal.enableEnhancements(eh.DISAMBIGUATE_ESCAPE_CODES | eh.REPORT_ALL_KEYS_AS_ESCAPE_CODES | eh.REPORT_ALTERNATE_KEYS);
        try terminal.enableFocusChange();
        try terminal.enterAlternateScreen();
        try terminal.enableMouseCapture();
        try terminal.enableRawMode();
        try terminal.disableLineWrap();
        try tty.writer().flush();
        stdx.err = null;

        const ws = terminal.windowSize() catch |err| {
            stdx.err = "Failed to get window size";
            return err;
        };
        const size: Rect = .{ .x = 0, .y = 0, .width = ws.columns, .height = ws.rows };
        return .{ .tty = tty, .cursor = .init(tty), .style = .init(tty), .terminal = terminal, .allocator = allocator, .size = size, .buffer = .{
            try buffer.Buffer.init(allocator, size),
            try buffer.Buffer.init(allocator, size),
        } };
    }

    pub fn deinit(self: *Tui) void {
        self.buffer[0].deinit();
        self.buffer[1].deinit();

        self.terminal.enableLineWrap() catch {};
        self.terminal.disableRawMode() catch {};
        self.terminal.disablesMouseCapture() catch {};
        self.terminal.leaveAlternateScreen() catch {};
        self.terminal.disablesFocusChange() catch {};
        self.terminal.disableEnhancements() catch {};
        self.terminal.restoreCp() catch {};
        self.tty.writer().flush() catch {};
    }

    pub fn resize(self: *Tui, size: Rect) !void {
        self.size = size;
        try self.buffer[0].resize(size);
        try self.buffer[1].resize(size);
        self.terminal.clear(.All) catch |err| {
            stdx.err = "Failed to resize 'Tui'";
            return err;
        };
    }

    fn diff_mod(self: *Tui, cur: Modifier, prev: Modifier) !void {
        const m: Modifier = @bitCast(@as(u16, @bitCast(cur)) ^ @as(u16, @bitCast(prev)));
        if (m.Bold) {
            if (cur.Bold) {
                try self.style.setAttribute(.Bold);
            } else {
                try self.style.setAttribute(.NormalIntensity);
            }
        }
        if (m.Dim) {
            if (cur.Dim) {
                try self.style.setAttribute(.Dim);
            } else {
                try self.style.setAttribute(.NormalIntensity);
            }
        }
        if (m.Italic) {
            if (cur.Italic) {
                try self.style.setAttribute(.Italic);
            } else {
                try self.style.setAttribute(.NoItalic);
            }
        }
        if (m.CrossedOut) {
            if (cur.CrossedOut) {
                try self.style.setAttribute(.CrossedOut);
            } else {
                try self.style.setAttribute(.NotCrossedOut);
            }
        }
        if (m.Underline) {
            if (cur.Underline) {
                try self.style.setAttribute(.Underlined);
            } else {
                try self.style.setAttribute(.NoUnderline);
            }
        }
        if (m.DoubleUnderline) {
            if (cur.DoubleUnderline) {
                try self.style.setAttribute(.DoubleUnderlined);
            } else {
                try self.style.setAttribute(.NoUnderline);
            }
        }
        if (m.UnderCurled) {
            if (cur.UnderCurled) {
                try self.style.setAttribute(.Undercurled);
            } else {
                try self.style.setAttribute(.NoUnderline);
            }
        }
        if (m.UnderDotted) {
            if (cur.UnderDotted) {
                try self.style.setAttribute(.Underdotted);
            } else {
                try self.style.setAttribute(.NoUnderline);
            }
        }
        if (m.UnderDashed) {
            if (cur.UnderDashed) {
                try self.style.setAttribute(.Underdashed);
            } else {
                try self.style.setAttribute(.NoUnderline);
            }
        }
    }

    pub fn draw(self: *Tui) !void {
        const cur = &self.buffer[self.curbuffer];
        var diffs = try cur.diffs(self.allocator, &self.buffer[~self.curbuffer]);
        const writer = self.tty.writer();
        stdx.err = "Failed to draw contents";
        var fg: termy.Style.Color = .Reset;
        var bg: termy.Style.Color = .Reset;
        var uc: termy.Style.Color = .Reset;
        var lastpos: ?struct { x: u16, y: u16 } = null;
        var mod: Modifier = .{};

        for (diffs.items) |d| {
            if (lastpos == null or lastpos.?.y != d.y or lastpos.?.x != d.x - 1) {
                try self.cursor.moveTo(d.x, d.y);
            }
            lastpos = .{ .x = d.x, .y = d.y };

            if (!std.meta.eql(fg, d.cell.fg)) {
                try self.style.setForegroundColor(d.cell.fg);
                fg = d.cell.fg;
            }
            if (!std.meta.eql(bg, d.cell.bg)) {
                try self.style.setBackgroundColor(d.cell.bg);
                bg = d.cell.bg;
            }
            if (!std.meta.eql(uc, d.cell.uc)) {
                try self.style.setUnderlineColor(d.cell.uc);
                uc = d.cell.uc;
            }
            if (mod != d.cell.mod) {
                try self.diff_mod(d.cell.mod, mod);
                mod = d.cell.mod;
            }
            if(d.continuation) continue;
            if(d.cell.symbol)|sym|
                try writer.writeAll(sym)
            else 
                try writer.writeAll(" ");
        }
        try self.style.setUnderlineColor(.Reset);
        try self.style.setForegroundColor(.Reset);
        try self.style.setBackgroundColor(.Reset);
        try self.diff_mod(.{}, mod);

        try writer.flush();
        stdx.err = null;

        diffs.deinit(self.allocator);
        self.curbuffer = ~self.curbuffer;
        self.buffer[self.curbuffer].clear();
    }

    pub fn render(self: *Tui, widget: anytype, area: Rect) !void {
        try widget.render(self.allocator, &self.buffer[self.curbuffer], area);
    }
};
