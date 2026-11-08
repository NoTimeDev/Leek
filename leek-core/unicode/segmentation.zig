//! This module provides utilities to dectect the start and end of graphemes 

// This code is based on https://www.unicode.org/reports/tr29/
// And https://github.com/unicode-rs/unicode-segmentation/blob/master/src/grapheme.rs

const std = @import("std");
const table = @import("table.zig");

const GraphemeContext = struct {
    force_hold: bool = false,
    ctx_type: ?ContexType = null,

    pub const ContexType = enum {
        GB9c,
        GB11,
        //12 + 13 -> 23
        GB23,
        Resolved
    };
};

pub const GraphemeResult = union(enum) {
    Boundary: usize,
    PreContext: usize,
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
    if(ctx.force_hold) return false;
    if(previous == .SOT or current == .EOT) return true;
    if (previous == .CR and current == .LF) {
        return false;
    } else if (matches(previous, .{ .CR, .Control, .LF }) or matches(current, .{ .CR, .Control, .LF })) {
        return true;
    } else if (previous == .L and matches(current, .{ .L, .V, .LV, .LVT })) {
        return false;
    } else if (matches(previous, .{ .LV, .V }) and matches(current, .{ .V, .T })) {
        return false;
    } else if (matches(previous, .{ .LVT, .T }) and current == .T) {
        return false;
    } else if (matches(current, .{ .Extend, .ZWJ })) {
        return false;
    } else if (current == .SpacingMark) {
        return false;
    } else if (previous == .Prepend) {
        return false;
    }

    return true;
}

pub const GraphemeCursor = struct {
    str: []const u8 = undefined,
    previous: table.GraphemeCat = .SOT,
    current: table.GraphemeCat = .SOT,
    eot_ret: bool = false,
    
    ctx: GraphemeContext = .{},
    found_linker: bool = false,
    found_picto: bool = false,
    context_needed: usize = 0,
    rj_count: usize = 0,

    len: usize,
    offset: usize,

    /// Creates a new grapheme cursor
    pub fn init(offset: usize, len: usize) GraphemeCursor {
        return .{ .offset = offset, .len = len };
    }

    /// Provides context to the grapheme cursor 
    pub fn provideContext(self: *GraphemeCursor, chunk: []const u8, len: usize) void{
        if(self.ctx.ctx_type)|ctx_type|{
            switch (ctx_type) {
                .GB9c => {
                    const result = self.handle_gbc9(chunk, self.context_needed-|len, self.context_needed);
                    if(result)|r|{
                        self.ctx.force_hold = r;
                        self.ctx.ctx_type = .Resolved;
                        self.context_needed = 0;
                        self.found_linker = false;
                    }else{
                        if (len >= self.context_needed) {
                            self.ctx.force_hold = false;
                            self.ctx.ctx_type = .Resolved;
                            self.context_needed = 0;
                            self.found_linker = false;
                        } else {
                            self.context_needed -= len;
                        }
                    }
                },
                .GB11 => {
                    const result = self.handle_gb11(chunk, self.context_needed-|len, self.context_needed);
                    if(result)|r|{
                        self.ctx.force_hold = r;
                        self.ctx.ctx_type = .Resolved;
                        self.context_needed = 0;
                        self.found_picto = false;
                    }else{
                        if (len >= self.context_needed) {
                            self.ctx.force_hold = false;
                            self.ctx.ctx_type = .Resolved;
                            self.context_needed = 0;
                            self.found_picto = false;
                        } else {
                            self.context_needed -= len;
                        }
                    }
                },
                .GB23 => {
                    const result = self.handle_gb23(chunk, self.context_needed-|len, self.context_needed);
                    if(result)|r|{
                        self.ctx.force_hold = r;
                        self.ctx.ctx_type = .Resolved;
                        self.context_needed = 0;
                        self.rj_count = 0;
                    }else{
                        if (len >= self.context_needed) {
                            self.ctx.force_hold = false;
                            self.ctx.ctx_type = .Resolved;
                            self.context_needed = 0;
                            self.rj_count = 0;
                        } else {
                            self.context_needed -= len;
                        }
                    }
                },
                .Resolved => {}
            }
        }
    }

    fn handle_gbc9(self: *GraphemeCursor, chunk: []const u8, byte_start: usize, byte_end: usize) ?bool{
        var iter = Utf8ReverseIterator.init(chunk[byte_start..byte_end]);
       
        while (iter.next())|cp|{
            switch(table.getGraphemeInCB(cp)){
                .Linker => self.found_linker = true,
                .Extend => {},
                .Consonant => return if(self.found_linker) true else false,
                .None => return false,
            }
        }
        return null;
    }

    fn handle_gb23(self: *GraphemeCursor, chunk: []const u8, chunk_start: usize, byte_end: usize) ?bool{
        var iter = Utf8ReverseIterator.init(chunk[byte_start..byte_end]);
      
        defer self.rj_count = 0;
        while (iter.next())|cp|{
            if(table.getGraphemeCat(cp) == .Regional_Indicator){
                self.rj_count+=1;
            }else{
                if(self.rj_count % 2 == 1){
                    return true;
                }
                return false;
            }
        }
        std.debug.print("{}, {}, {}\n", .{self.len, byte_start, byte_end});
        if(self.len-byte_end == 0){
            if(self.rj_count % 2 == 1){
                return true;
            }
            return false;
        }
        return null;
    }

    fn handle_gb11(self: *GraphemeCursor, chunk: []const u8, byte_start: usize, byte_end: usize) ?bool{
        var iter = Utf8ReverseIterator.init(chunk[byte_start..byte_end]);
        if(table.getGraphemeCat(iter.next() orelse return null) != .ZWJ) return false;

        while (iter.next())|cp|{
            if(table.getGraphemeEmoji(cp)){
                self.found_picto = true;
                return true;
            }else{
                if(table.getGraphemeCat(cp) != .Extend) {
                    return false;
                }
            }
        }
        return null;
    }

    /// Finds the next boundary of after a cursor position
    pub fn next_boundary(self: *GraphemeCursor, chunk: []const u8, chunk_start: usize) !?GraphemeResult {
        if(self.context_needed != 0){
            return .{ .PreContext = self.context_needed };
        }
        if (self.offset == self.len) if (!self.eot_ret) {
            self.eot_ret = true;
            return .{ .Boundary = self.offset };
        } else {
            return null;
        };
        if (self.offset > self.len or chunk_start > self.offset) return .InvalidOffset;
        const start = self.offset -| chunk_start;
        var iter = (try std.unicode.Utf8View.init(chunk[self.offset -| chunk_start..])).iterator();
        var end: usize = 0;
        while (true){
            const ch = iter.nextCodepoint() orelse {
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

            if(table.getGraphemeInCB(ch) == .Consonant and self.offset != 0 and self.ctx.ctx_type != .Resolved){
                if(end == 0){
                    self.context_needed = chunk_start + end;
                    self.ctx.ctx_type = .GB9c;
                    return .{ .PreContext = chunk_start + end };
                }
                const x = self.handle_gbc9(chunk, start, start+end) orelse {
                    self.context_needed = chunk_start + end;
                    self.ctx.ctx_type = .GB9c;
                    return .{ .PreContext = chunk_start + end };
                };
                if(x) self.ctx.force_hold = true;
            }

            if(table.getGraphemeEmoji(ch) and self.offset != 0 and self.ctx.ctx_type != .Resolved){
                if(end == 0){
                    self.context_needed = chunk_start + end;
                    self.ctx.ctx_type = .GB11;
                    return .{ .PreContext = chunk_start + end };
                }
                const x = self.handle_gb11(chunk, start, start+end) orelse {
                    self.context_needed = chunk_start + end;
                    self.ctx.ctx_type = .GB11;
                    return .{ .PreContext = chunk_start + end };
                };
                self.rj_count = 0;
                if(x) self.ctx.force_hold = true;
            }

            if(table.getGraphemeCat(ch) == .Regional_Indicator and self.offset != 0 and self.ctx.ctx_type != .Resolved){
                if(end == 0){
                    self.context_needed = chunk_start + end;
                    self.ctx.ctx_type = .GB23;
                    return .{ .PreContext = chunk_start + end };
                }
                const x = self.handle_gb23(chunk, start, start+end) orelse {
                    self.context_needed = chunk_start + end;
                    self.ctx.ctx_type = .GB23;
                    return .{ .PreContext = chunk_start + end };
                };
                if(x) self.ctx.force_hold = true;
            }
            end += try std.unicode.utf8CodepointSequenceLength(ch);

            self.previous = self.current;
            self.current = table.getGraphemeCat(ch);
            const  pre = self.offset;
            self.offset += try std.unicode.utf8CodepointSequenceLength(ch);

            if (shouldBreak(self.previous, self.current, self.ctx) and self.previous != .SOT){
                return .{ .Boundary = pre };
            }
            self.ctx = .{};
        }
        return null;
    }
};

pub const Utf8ReverseIterator = struct {
    bytes: []const u8,
    offset: usize,

    pub fn init(bytes: []const u8) Utf8ReverseIterator {
        return .{
            .bytes = bytes,
            .offset = bytes.len,
        };
    }

    pub fn next(self: *Utf8ReverseIterator) ?u21 {
        if (self.offset == 0) return null;

        var start = self.offset - 1;

        while (start > 0 and (self.bytes[start] & 0xC0) == 0x80) {
            start -= 1;
        }

        const cp = std.unicode.utf8Decode(
            self.bytes[start..self.offset],
        ) catch return null;

        self.offset = start;
        return cp;
    }
};

pub const GraphemeIterator = struct {
    gc: GraphemeCursor,
    offset: usize,
    len: usize,
    str: []const u8,

    /// Creates a grapheme iterator from a utf-8 string
    pub fn init(str: []const u8, len: usize) GraphemeIterator {
        return .{ .gc = .init(0, len), .offset = 0, .len = len, .str = str };
    }

    /// Moves to the next grapheme in the iterator
    pub fn next(self: *GraphemeIterator) !?[]const u8 {
        const start = self.offset;
         while(true){
            switch(try self.gc.next_boundary(self.str[start..], start) orelse return null){
                // Impossible on contiguous data stream
                .PrevChunk, .NextChunk => unreachable,
                .PreContext => |p|{
                    const slice = self.str[0..p];
                    self.gc.provideContext(slice, slice.len);
                },
                .Boundary => |b| {self.offset = b; break;},
                .InvalidOffset => return error.InvalidOffset,
            }
        }
        return self.str[start..self.offset];
    }

    /// Counts the amount of items in the iterator, this is costly as it iterates through everything to count the elements
    pub fn count(self: *GraphemeIterator) !usize {
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
    const str: []const u8 = "🇯🇲🇺🇸🇨";
    var iter: GraphemeIterator = .init(str, str.len);
    while (try iter.next())|grapheme| {
        std.debug.print("{s}\n", .{grapheme});
    }
    std.debug.print("Len: {}\n", .{try iter.count()});
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
