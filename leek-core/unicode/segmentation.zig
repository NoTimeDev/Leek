const std = @import("std");
const table = @import("table.zig");

const GraphemeContext = struct {};

pub const GraphemeResult = union(enum) {
    Boundary: usize,
    NextChunk,
    PrevChunk,
    InvalidOffset,
};

fn matches(value: anytype, comptime values: anytype) bool {
    inline for (values) |v| {
        if (value == v) return true;
    }

    return false;
}

fn shouldBreak(previous: table.GraphemeCat, current: table.GraphemeCat, ctx: GraphemeContext) bool {
    _ = ctx;
    if (previous == .CR and current == .LF) return false else if (matches(previous, .{ .CR, .Control, .LF }) or matches(current, .{ .CR, .Control, .LF })) return true else if (previous == .L and matches(current, .{ .L, .V, .LV, .LVT })) return false else if (matches(previous, .{ .LV, .V }) and matches(current, .{ .V, .T })) return false else if (matches(previous, .{ .LVT, .T }) and current == .T) return false else if (matches(current, .{ .Extend, .ZWJ })) return false else if (current == .SpacingMark) return false else if (previous == .Prepend) return false;

    return true;
}

pub const GraphemeCursor = struct {
    str: []const u8 = undefined,
    previous: ?table.GraphemeCat = null,
    current: ?table.GraphemeCat = null,
    eot_ret: bool = false,
    ctx: GraphemeContext = .{},
    len: usize,
    offset: usize,

    /// Creates a new grapheme cursor
    pub fn init(offset: usize, len: usize) GraphemeCursor {
        return .{ .offset = offset, .len = len };
    }

    /// Finds the next boundary of after a cursor position
    pub fn next_boundary(self: *GraphemeCursor, chunk: []const u8, chunk_start: usize) !?GraphemeResult {
        if (self.offset == self.len) if (!self.eot_ret) {
            self.eot_ret = true;
            return .{ .Boundary = self.offset };
        } else {
            return null;
        };
        if (self.offset > self.len or chunk_start > self.offset) return .InvalidOffset;
        var iter = (try std.unicode.Utf8View.init(chunk[self.offset -| chunk_start..])).iterator();
        while (true) {
            var ch = iter.nextCodepoint() orelse {
                if (self.offset == self.len) {
                    if (!self.eot_ret) {
                        self.eot_ret = true;
                        return .{ .Boundary = self.offset };
                    } else {
                        return null;
                    }
                }
                return .NextChunk;
            };
            self.previous = self.current;
            self.current = table.getGraphemeCat(ch);
            var pre = self.offset;
            self.offset += try std.unicode.utf8CodepointSequenceLength(ch);
            if (self.previous == null) {
                ch = iter.nextCodepoint() orelse {
                    if (self.offset == self.len) {
                        if (!self.eot_ret) {
                            self.eot_ret = true;
                            return .{ .Boundary = self.offset };
                        } else {
                            return null;
                        }
                    }
                    return .NextChunk;
                };
                pre = self.offset;
                self.offset += try std.unicode.utf8CodepointSequenceLength(ch);
                self.previous = self.current;
                self.current = table.getGraphemeCat(ch);
            }
            if (shouldBreak(self.previous orelse unreachable, self.current orelse unreachable, self.ctx)) return .{ .Boundary = pre };
        }
        return null;
    }
};

pub const GraphemeInterator = struct {
    gc: GraphemeCursor,
    offset: usize,
    len: usize,
    str: []const u8,

    /// Creates a grapheme iterator from a utf-8 string
    pub fn init(str: []const u8, len: usize) GraphemeInterator {
        return .{ .gc = .init(0, len), .offset = 0, .len = len, .str = str };
    }

    /// Moves to the next grapheme in the iterator
    pub fn next(self: *GraphemeInterator) !?[]const u8 {
        const start = self.offset;
        self.offset = (try self.gc.next_boundary(self.str[start..], start) orelse return null).Boundary;
        return self.str[start..self.offset];
    }

    /// Counts the amount of items in the iterator, this is costly as it iterates through everything to count the elements
    pub fn count(self: *GraphemeInterator) !usize {
        const saved = self.*;
        self.* = .init(saved.str, saved.len);
        var c: usize = 0;
        while (try self.next()) |_| {
            c += 1;
        }
        self.* = saved;
        return c;
    }
};

test "Count" {
    const str: []const u8 = "éeá̧ae\u{0301}pe\u{0301}oa\u{0301}\u{0327}";
    var iter: GraphemeInterator = .init(str, str.len);
    while (try iter.next()) |grapheme| {
        std.debug.print("{s}\n", .{grapheme});
    }
    std.debug.print("Iterator Count: {}\n", .{try iter.count()});
}

test "GB3-5" {
    try std.testing.expect(!shouldBreak(.CR, .LF, .{}));

    try std.testing.expect(shouldBreak(.CR, .Any, .{}));
    try std.testing.expect(shouldBreak(.LF, .Any, .{}));
    try std.testing.expect(shouldBreak(.Control, .Any, .{}));

    try std.testing.expect(shouldBreak(.Any, .CR, .{}));
    try std.testing.expect(shouldBreak(.Any, .LF, .{}));
    try std.testing.expect(shouldBreak(.Any, .Control, .{}));
}

test "GB6-8" {
    try std.testing.expect(!shouldBreak(.L, .L, .{}));
    try std.testing.expect(!shouldBreak(.L, .V, .{}));
    try std.testing.expect(!shouldBreak(.L, .LV, .{}));
    try std.testing.expect(!shouldBreak(.L, .LVT, .{}));

    try std.testing.expect(!shouldBreak(.LV, .V, .{}));
    try std.testing.expect(!shouldBreak(.LV, .T, .{}));

    try std.testing.expect(!shouldBreak(.V, .V, .{}));
    try std.testing.expect(!shouldBreak(.V, .T, .{}));

    try std.testing.expect(!shouldBreak(.LVT, .T, .{}));
    try std.testing.expect(!shouldBreak(.T, .T, .{}));
}

test "GB9a-c" {
    try std.testing.expect(!shouldBreak(.Extend, .ZWJ, .{}));
    try std.testing.expect(!shouldBreak(.Any, .SpacingMark, .{}));
    try std.testing.expect(!shouldBreak(.Prepend, .Any, .{}));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(table);
}
