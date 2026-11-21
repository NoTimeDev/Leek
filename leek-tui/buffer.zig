const termy = @import("root.zig").termy;
const root = @import("root.zig");
const std = @import("std");
const stdx = @import("root.zig").stdx;
const width = stdx.unicode.width;

pub const Modifier = packed struct(u16) {
    Bold: bool = false,
    Dim: bool = false,
    Italic: bool = false,
    Underline: bool = false,
    DoubleUnderline: bool = false,
    UnderCurled: bool = false,
    UnderDotted: bool = false,
    UnderDashed: bool = false,
    CrossedOut: bool = false,
    _: u7 = 0,
};

pub const Cell = struct {
    /// A grapheme cluster
    symbol: []const u8,
    bg: termy.Style.Color,
    fg: termy.Style.Color,
    uc: termy.Style.Color,
    mod: Modifier,

    pub fn empty() Cell {
        return .{
            .symbol = "",
            .bg = .Reset,
            .fg = .Reset,
            .uc = .Reset,
            .mod = .{},
        };
    }

    pub fn eq(self: *const Cell, other: *const Cell) bool {
        return std.mem.eql(u8, self.symbol, other.symbol) and
            std.meta.eql(self.bg, other.bg) and
            std.meta.eql(self.fg, other.fg) and
            std.meta.eql(self.uc, other.uc) and
            self.mod == other.mod;
    }

    //----I Love Chaining----
    pub fn setSymbol(self: *Cell, sym: []const u8) *Cell {
        self.symbol = sym;
        return self;
    }

    pub fn setBg(self: *Cell, bg: termy.Style.Color) *Cell {
        self.bg = bg;
        return self;
    }

    pub fn setUc(self: *Cell, uc: termy.Style.Color) *Cell {
        self.uc = uc;
        return self;
    }

    pub fn setFg(self: *Cell, fg: termy.Style.Color) *Cell {
        self.fg = fg;
        return self;
    }

    pub fn setMod(self: *Cell, mod: Modifier) *Cell {
        self.mod = mod;
        return self;
    }
};

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    cells: std.ArrayList(Cell),
    size: root.Rect,

    pub fn init(alloctor: std.mem.Allocator, size: root.Rect) !Buffer {
        var cells: std.ArrayList(Cell) = .empty;
        cells.appendNTimes(alloctor, .empty(), size.x * size.y) catch |err| {
            stdx.err = "Failed to init buffer";
            return err;
        };
        return .{
            .allocator = alloctor,
            .size = size,
            .cells = cells,
        };
    }

    /// clears a buffer
    pub inline fn clear(self: *Buffer) void {
        for (self.cells.items) |*cell| {
            cell.* = .empty();
        }
    }

    /// Resizes the buffer
    pub fn resize(self: *Buffer, size: root.Rect) !void {
        const area = size.x * size.y;
        stdx.err = "Failed to resize internal buffer";
        if (self.cells.items.len > area) {
            try self.cells.shrinkAndFreePrecise(self.allocator, area);
        } else if (self.cells.items.len < area) {
            try self.cells.appendNTimes(self.allocator, .empty(), area - self.cells.items.len);
        }
        stdx.err = null;
        self.clear();
    }

    /// This trusts the programmer, anything outside the bounds of the array is undefined behaviour
    pub inline fn get(self: *Buffer, x: u16, y: u16) *Cell {
        return &self.cells.items[x + (y * self.size.x)];
    }

    pub const Diff = struct { x: u16, y: u16, cell: Cell };

    /// Returns the cells that need to be drawn
    pub fn diffs(self: *const Buffer, allocator: std.mem.Allocator, other: *const Buffer) !std.ArrayList(Diff) {
        var difs: std.ArrayList(Diff) = .empty;
        var idx: usize = 0;
        var invalidate: usize = 0;
        while (idx < self.cells.items.len) : (idx += 1) {
            const cur = &self.cells.items[idx];
            const prev = &other.cells.items[idx];

            stdx.err = "Failed to get grapheme size";
            const cw = try width.graphemeWidth(cur.symbol, false);
            const pw = try width.graphemeWidth(prev.symbol, false);
            stdx.err = null;
            invalidate = @max(@max(cw, pw), invalidate) -| 1;
            idx += cw -| 1;

            if (!cur.eq(prev) or invalidate > 0) {
                const y = if (idx == 0) 0 else @divTrunc(idx, self.size.x);
                difs.append(allocator, .{
                    .x = @intCast((idx - y * self.size.x) + 1),
                    .y = @intCast(y + 1),
                    .cell = self.cells.items[idx],
                }) catch |err| {
                    stdx.err = "Failed to diff";
                    return err;
                };
            }
        }
        return difs;
    }
    pub fn deinit(self: *Buffer) void {
        self.cells.deinit(self.allocator);
    }
};
