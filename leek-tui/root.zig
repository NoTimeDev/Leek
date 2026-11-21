//! This module provides abstractions over termy-zig to make building tui easier

pub const termy = @import("termy");
const core = @import("core");
const std = @import("std");

pub const Tui = struct {
    tty: *termy.Tty,
    cursor: termy.Cursor,
    style: termy.Style,
    terminal: termy.Terminal,
    allocator: std.mem.Allocator,

    pub fn init(tty: *termy.Tty, allocator: std.mem.Allocator) Tui{
        return .{
            .tty = tty,
            .cursor = .init(tty),
            .style = .init(tty),
            .terminal = .init(tty),
            .allocator = allocator
        };
    }

    pub fn enter(self: *Tui) !void{
        core.err = "Failed to set up tui";
        const eh = termy.Terminal.Enhancements;
        try self.terminal.enableCp();
        try self.terminal.enableEnhancements(eh.DISAMBIGUATE_ESCAPE_CODES | eh.REPORT_ALL_KEYS_AS_ESCAPE_CODES | eh.REPORT_ALTERNATE_KEYS);
        try self.terminal.enableFocusChange();
        try self.terminal.enterAlternateScreen();
        try self.terminal.enableMouseCapture();
        try self.terminal.enableRawMode();
        try self.terminal.disableLineWrap();
        try self.tty.writer().flush();
        core.err = null;
    }

    pub fn deinit(self: *Tui) void{
        self.terminal.enableLineWrap() catch {};
        self.terminal.disableRawMode() catch {};
        self.terminal.disablesMouseCapture() catch {};
        self.terminal.leaveAlternateScreen() catch {};
        self.terminal.disablesFocusChange() catch {};
        self.terminal.disableEnhancements() catch {};
        self.terminal.restoreCp() catch {};
        self.tty.writer().flush() catch {};
    }
};
