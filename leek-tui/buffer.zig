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
    symbol: ?[]const u8,
    bg: termy.Style.Color,
    fg: termy.Style.Color,
    uc: termy.Style.Color,
    mod: Modifier,

    pub fn empty() Cell {
        return .{
            .symbol = null,
            .bg = .Reset,
            .fg = .Reset,
            .uc = .Reset,
            .mod = .{},
        };
    }

    pub fn eq(self: *const Cell, other: *const Cell) bool {
        return (if (self.symbol) |a|
            if (other.symbol) |b| std.mem.eql(u8, a, b) else false
        else
            other.symbol == null) and
            std.meta.eql(self.bg, other.bg) and
            std.meta.eql(self.fg, other.fg) and
            std.meta.eql(self.uc, other.uc) and
            self.mod == other.mod;
    }

    //----I Love Chaining----

    ///Allocator must be used in Buffer, and in previous setSymbol calls
    pub fn setSymbol(self: *Cell, sym: []const u8, allocator: std.mem.Allocator) *Cell {
        // Maybe change this to an error later on but for now, die!
        if (self.symbol) |sy| allocator.free(sy);
        self.symbol = allocator.dupe(u8, sym) catch null;
        return self;
    }

    ///Allocator must be used in Buffer, and in previous setSymbol calls
    pub fn setSymbolFromChar(self: *Cell, ch: u21, allocator: std.mem.Allocator) *Cell {
        if (self.symbol) |sy| allocator.free(sy);

        const result = allocator.alloc(u8, 4) catch {
            self.symbol = null;
            return self;
        };

        const len = std.unicode.utf8Encode(ch, result) catch {
            allocator.free(result);
            self.symbol = null;
            return self;
        };
        self.symbol = allocator.realloc(result, len) catch {
            allocator.free(result);
            self.symbol = null;
            return self;
        };
        return self;
    }

    pub fn deinit(self: *Cell, allocator: std.mem.Allocator) void {
        if (self.symbol) |sym|
            allocator.free(sym);
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

    pub fn init(allocator: std.mem.Allocator, size: root.Rect) !Buffer {
        var cells: std.ArrayList(Cell) = .empty;
        cells.appendNTimes(allocator, .empty(), size.width * size.height) catch |err| {
            stdx.err = "Failed to init buffer";
            return err;
        };
        return .{
            .allocator = allocator,
            .size = size,
            .cells = cells,
        };
    }

    /// clears a buffer
    pub inline fn clear(self: *Buffer) void {
        for (self.cells.items) |*cell| {
            if (cell.symbol) |sym| self.allocator.free(sym);
            cell.* = .empty();
        }
    }

    /// Resizes the buffer
    pub fn resize(self: *Buffer, size: root.Rect) !void {
        const area = size.width * size.height;
        stdx.err = "Failed to resize internal buffer";
        if (self.cells.items.len > area) {
            for (self.cells.items[area..]) |*cell| {
                cell.deinit(self.allocator);
            }
            try self.cells.shrinkAndFreePrecise(self.allocator, area);
        } else if (self.cells.items.len < area) {
            try self.cells.appendNTimes(self.allocator, .empty(), area - self.cells.items.len);
        }
        self.size = size;
        stdx.err = null;
        self.clear();
    }

    /// This trusts the programmer, anything outside the bounds of the array is undefined behaviour
    pub inline fn get(self: *Buffer, x: u16, y: u16) *Cell {
        return &self.cells.items[x + (y * self.size.width)];
    }

    pub const Diff = struct {
        x: u16,
        y: u16,
        continuation: bool = false,
        cell: *const Cell,
    };

    /// Returns the cells that need to be drawn
    pub fn diffs(self: *const Buffer, allocator: std.mem.Allocator, other: *const Buffer) !std.ArrayList(Diff) {
        var difs: std.ArrayList(Diff) = .empty;
        var idx: usize = 0;
        var invalidate: usize = 0;
        var continuation: usize = 0;

        while (idx < self.cells.items.len) {
            const cur = &self.cells.items[idx];
            const prev = &other.cells.items[idx];

            stdx.err = "Failed to get grapheme size";
            const cw = if (cur.symbol) |sym| try width.graphemeWidth(sym, false) else 1;
            const pw = if (prev.symbol) |sym| try width.graphemeWidth(sym, false) else 1;
            stdx.err = null;

            const is_continuation = continuation > 0;
            const changed = !cur.eq(prev);
            if (changed or invalidate > 0) {
                const x = idx % self.size.width;
                const y = idx / self.size.width;
                difs.append(allocator, .{
                    .x = @intCast(x + 1),
                    .y = @intCast(y + 1),
                    .continuation = is_continuation,
                    .cell = cur,
                }) catch |err| {
                    stdx.err = "Failed to diff";
                    return err;
                };
            }
            if (continuation > 0) {
                continuation -= 1;
            }

            if (cur.symbol != null and cw > 1) {
                continuation = cw - 1;
            }

            if (changed) {
                invalidate = @max(cw, pw) - 1;
            } else if (invalidate > 0) {
                invalidate -= 1;
            }
            idx += 1;
        }
        return difs;
    }
    pub fn deinit(self: *Buffer) void {
        for (self.cells.items) |*c| {
            c.deinit(self.allocator);
        }
        self.cells.deinit(self.allocator);
    }
};
