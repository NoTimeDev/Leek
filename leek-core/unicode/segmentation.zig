const std = @import("std");
const table = @import("table.zig");

fn matches(value: anytype, comptime values: anytype) bool {
    inline for (values) |v| {
        if (value == v) return true;
    }
    return false;
}

/// An Zero-allocation tool to reverse iterate through utf8 codepoints 
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

fn shouldBreak(prev: table.GraphemeCat, curr: table.GraphemeCat) bool {
    // zig fmt: off
    if(prev == .CR and curr == .LF) return false
    else if(matches(prev, [_]table.GraphemeCat{.Control, .CR, .LF})) return true
    else if(matches(curr, [_]table.GraphemeCat{.Control, .CR, .LF})) return true
    else if(prev == .L and matches(curr, [_]table.GraphemeCat{.L, .V, .LV, .LVT})) return false 
    else if(matches(prev, [_]table.GraphemeCat{.LV, .V}) and matches(curr, [_]table.GraphemeCat{.V, .T})) return false 
    else if(matches(prev, [_]table.GraphemeCat{.LVT, .T}) and curr == .T) return false 
    else if(matches(curr, [_]table.GraphemeCat{.Extend, .ZWJ})) return false 
    else if(curr == .SpacingMark) return false
    else if(prev == .Prepend) return false
    else return true;
    // zig fmt: on
}

pub const GraphemeInfo = union(enum) { PrevChunk, NextChunk, Boundary: usize, PreContext: usize };

/// A cursor segmentor for grapheme cluster.
///
/// This is useful for stuff like ropes where the size is known but data is not contiguous.
pub const GraphemeCursor = struct {
    offset: usize,
    len: usize,
    prev: ?table.GraphemeCat = null,
    curr: ?table.GraphemeCat = null,
    resuming: bool = false,
    reached_eot: bool = false,
    reached_sot: bool = false,
    state: ?ContextType = null,
    prectxend: ?usize = null,
    force: bool = false,
    prec_ch: u21 = 0,
    curr_ch: u21 = 0,
    first_context_request: bool = false,

    count_ri: usize = 0,

    const ContextType = enum {
        GB9c,
        GB11,
        GB12_13,
    };

    /// Creates a new GraphemeCursor
    pub fn init(offset: usize, len: usize) GraphemeCursor {
        return .{ .offset = offset, .len = len };
    }

    /// Provides context into the cursor
    pub fn provideContext(self: *GraphemeCursor, chunk: []const u8, chunk_start: usize) ?usize {
        const state = self.state orelse return null;
        const end = self.prectxend orelse return null;

        defer self.first_context_request = false;
        switch (state) {
            .GB9c => {
                var iter: Utf8ReverseIterator = .init(chunk[0..end -| chunk_start]);
                while (iter.next()) |ch| {
                    const incb = table.getGraphemeInCB(ch);
                    if (incb == .Extend) continue;
                    if (incb == .Linker) self.force = true;
                    return null;
                }
                return null;
            },
            .GB11 => {
                var iter: Utf8ReverseIterator = .init(chunk[0..end -| chunk_start]);
                if (self.first_context_request) {
                    if (table.getGraphemeCat(iter.next() orelse return null) != .ZWJ) return null;
                }
                while (iter.next()) |ch| {
                    const cat = table.getGraphemeCat(ch);
                    if (table.getGraphemeEmoji(ch) == true) {
                        self.force = true;
                        return null;
                    }
                    if (cat != .Extend) return null;
                }
            },
            .GB12_13 => {
                var iter: Utf8ReverseIterator = .init(chunk[0..end -| chunk_start]);
                while (iter.next()) |ch| {
                    const cat = table.getGraphemeCat(ch);
                    if (cat != .Regional_Indicator) {
                        if (self.count_ri % 2 == 1) self.force = true;
                        return null;
                    }
                    //Must be a Regional_Indicator
                    self.count_ri += 1;
                }
                if (chunk_start == 0) {
                    if (self.count_ri % 2 == 1) self.force = true;
                    return null;
                }
            },
        }
        if (chunk_start == 0) return null;
        self.prectxend = chunk_start;
        return null;
    }

    /// Moves to the next boundary from a position.
    pub fn nextBoundary(self: *GraphemeCursor, chunk: []const u8, chunk_start: usize) !?GraphemeInfo {
        if (self.offset == self.len) {
            if (!self.reached_eot and self.len != 0) {
                self.reached_eot = true;
                return .{ .Boundary = self.offset };
            }
            return null;
        }
        if (self.offset > self.len or chunk_start > self.offset) return error.InvalidOffset;
        var iter: std.unicode.Utf8Iterator = (try std.unicode.Utf8View.init(chunk[self.offset -| chunk_start..])).iterator();
        var ch = iter.nextCodepoint() orelse return .NextChunk;
        while (true) {
            self.prev = self.curr;
            self.curr = table.getGraphemeCat(ch);
            if (self.prev == null) {
                self.offset += try std.unicode.utf8CodepointSequenceLength(ch);
                ch = iter.nextCodepoint() orelse {
                    if (!self.reached_eot) {
                        self.reached_eot = true;
                        return .{ .Boundary = self.offset };
                    }
                    return .NextChunk;
                };
                continue;
            }
    
            //CL|C
            const should_break = shouldBreak(self.prev orelse unreachable, self.curr orelse unreachable);
            if (!self.force and should_break) {
                const incb = table.getGraphemeInCB(ch);
                if (incb == .Consonant) {
                    if (self.resuming) {
                        self.prectxend = null;
                        self.resuming = false;
                        self.state = null;
                    } else {
                        self.resuming = true;
                        self.state = .GB9c;
                        self.prectxend = self.offset;
                        return .{ .PreContext = self.offset };
                    }
                }

                if (table.getGraphemeEmoji(ch)) {
                    if (self.resuming) {
                        self.prectxend = null;
                        self.resuming = false;
                        self.state = null;
                    } else {
                        self.first_context_request = true;
                        self.resuming = true;
                        self.state = .GB11;
                        self.prectxend = self.offset;
                        return .{ .PreContext = self.offset };
                    }
                }
                if (self.prev == .Regional_Indicator and self.curr == .Regional_Indicator) {
                    if (self.resuming) {
                        self.prectxend = null;
                        self.resuming = false;
                        self.state = null;
                        self.count_ri = 0;
                    } else {
                        self.count_ri = 0;
                        self.resuming = true;
                        self.state = .GB12_13;
                        self.prectxend = self.offset;
                        return .{ .PreContext = self.offset };
                    }
                }

                const end = self.offset;
                self.offset += try std.unicode.utf8CodepointSequenceLength(ch);
                return .{ .Boundary = end };
            }
            self.resuming = false;
            self.force = false;

            self.offset += try std.unicode.utf8CodepointSequenceLength(ch);
            ch = iter.nextCodepoint() orelse {
                if (!self.reached_eot) {
                    self.reached_eot = true;
                    return .{ .Boundary = self.offset };
                }
                return .NextChunk;
            };
        }
        return null;
    }

    /// Moves to the previous boundary from a position.
    pub fn prevBoundary(self: *GraphemeCursor, chunk: []const u8, chunk_start: usize) !?GraphemeInfo {
        if (self.offset == 0) {
            if (!self.reached_sot and self.len != 0) {
                self.reached_sot = true;
                return .{ .Boundary = self.offset };
            }
            return null;
        }
        if (self.offset > self.len or chunk_start > self.offset) return error.InvalidOffset;
        var iter: Utf8ReverseIterator = .init(chunk[0..@min(self.offset -| chunk_start, chunk.len)]);
        var ch = iter.next() orelse return .PrevChunk; 
        while (true){
            self.curr_ch = self.prec_ch;
            self.curr = self.prev;
            self.prec_ch = ch;
            self.prev = table.getGraphemeCat(ch);
            if(self.curr == null){
                self.offset -= try std.unicode.utf8CodepointSequenceLength(ch);
                ch = iter.next() orelse {
                    if(!self.reached_sot){
                        self.reached_sot = true;
                        return .{ .Boundary = self.offset };
                    }
                    return .NextChunk;
                };
                continue;
            }
            
            const should_break =  shouldBreak(self.prev orelse unreachable, self.curr orelse unreachable);
            if(!self.force and should_break){

                const incb = table.getGraphemeInCB(self.curr_ch);
                if(incb == .Consonant){
                    if (self.resuming) {
                        self.prectxend = null;
                        self.resuming = false;
                        self.state = null;
                    } else {
                        self.resuming = true;
                        self.state = .GB9c;
                        const start = self.offset;
                        
                        self.offset+=try std.unicode.utf8CodepointSequenceLength(self.curr_ch);
                        self.prev = null;
                        
                        self.prectxend = start;
                        return .{ .PreContext = start};
                    }
                }
                if (table.getGraphemeEmoji(self.curr_ch)) {
                    if (self.resuming) {
                        self.prectxend = null;
                        self.resuming = false;
                        self.state = null;
                    } else {
                        self.first_context_request = true;
                        self.resuming = true;
                        self.state = .GB11;
                        const start = self.offset;
                        
                        self.offset+=try std.unicode.utf8CodepointSequenceLength(self.curr_ch);
                        self.prev = null;

                        self.prectxend = start;
                        return .{ .PreContext = start };
                    }
                }
                if (self.prev == .Regional_Indicator and self.curr == .Regional_Indicator) {
                    if (self.resuming) {
                        self.prectxend = null;
                        self.resuming = false;
                        self.state = null;
                        self.count_ri = 0;
                    } else {
                        self.count_ri = 0;
                        self.resuming = true;
                        self.state = .GB12_13;
                        const start = self.offset;
                        
                        self.offset+=try std.unicode.utf8CodepointSequenceLength(self.curr_ch);
                        self.prev = null;
                        
                        self.prectxend = start;
                        return .{ .PreContext = start };
                    }
                }
           
                const start = self.offset;
                self.offset -= try std.unicode.utf8CodepointSequenceLength(ch);
                return .{ .Boundary = start };
            }
            self.resuming = false;
            self.force = false;
            
            self.offset -= try std.unicode.utf8CodepointSequenceLength(ch);
            ch = iter.next() orelse {
                if(!self.reached_sot){
                    self.reached_sot = true;
                    return .{ .Boundary = self.offset };
                }
                return .NextChunk;
            };
        }
        return null;
    }
};

/// A tool to interate through graphemes in a utf8 string
pub const GraphemeIterator = struct {
    str: []const u8,
    offset: usize = 0,
    gc: GraphemeCursor,

    pub fn init(str: []const u8) GraphemeIterator {
        return .{ .str = str, .gc = .init(0, str.len) };
    }

    pub fn next(self: *GraphemeIterator) !?[]const u8 {
        const start = self.offset;
        while (true) {
            const ginfo = ((try self.gc.nextBoundary(self.str[start..], start)) orelse return null);
            switch (ginfo) {
                .PreContext => |end| {
                    _ = self.gc.provideContext(self.str[0..end], 0);
                    continue;
                },
                .Boundary => |pos| {
                    self.offset = pos;
                    break;
                },
                else => unreachable,
            }
        }
        return self.str[start..self.offset];
    }

    pub fn count(self: *GraphemeIterator) !usize {
        const saved = self.*;
        self.* = .init(saved.str);
        var c: usize = 0;
        while (try self.next()) |_| {
            c += 1;
        }
        self.* = saved;
        return c;
    }
};

/// A tool to reverse interate through graphemes in a utf8 string
pub const GraphemeReverseIterator = struct {
    str: []const u8,
    offset: usize,
    gc: GraphemeCursor,

    pub fn init(str: []const u8) GraphemeReverseIterator {
        return .{ .str = str, .offset = str.len, .gc = .init(str.len, str.len) };
    }

    pub fn next(self: *GraphemeReverseIterator) !?[]const u8 {
        const end = self.offset;
        while (true) {
            const ginfo = ((try self.gc.prevBoundary(self.str, 0)) orelse return null);
            switch (ginfo) {
                .PreContext => |e| {
                    _ = self.gc.provideContext(self.str[0..e], 0);
                    continue;
                },
                .Boundary => |pos| {
                    self.offset = pos;
                    break;
                },
                else => unreachable,
            }
        }
        return self.str[self.offset..end];
    }

    pub fn count(self: *GraphemeReverseIterator) !usize {
        const saved = self.*;
        self.* = .init(saved.str);
        var c: usize = 0;
        while (try self.next()) |_| {
            c += 1;
        }
        self.* = saved;
        return c;
    }
};
test {
    std.testing.refAllDecls(table);
    std.testing.refAllDecls(@This());
}

// These might not be good test lowkey but idc
 
//START_EAT
test "Test 26"{
   var gc: GraphemeIterator = .init("\u{000D}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 27"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{000D}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 28"{
   var gc: GraphemeIterator = .init("\u{000D}\u{000A}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 29"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{000A}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 30"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 31"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{0000}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 32"{
   var gc: GraphemeIterator = .init("\u{000D}\u{094D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 33"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{094D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 34"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0300}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 35"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{0300}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 36"{
   var gc: GraphemeIterator = .init("\u{000D}\u{200C}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 37"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{200C}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 38"{
   var gc: GraphemeIterator = .init("\u{000D}\u{200D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 39"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{200D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 40"{
   var gc: GraphemeIterator = .init("\u{000D}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 41"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 42"{
   var gc: GraphemeIterator = .init("\u{000D}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 43"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{06DD}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 44"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0903}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 45"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{0903}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 46"{
   var gc: GraphemeIterator = .init("\u{000D}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 47"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{1100}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 48"{
   var gc: GraphemeIterator = .init("\u{000D}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 49"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{1160}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 50"{
   var gc: GraphemeIterator = .init("\u{000D}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 51"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{11A8}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 52"{
   var gc: GraphemeIterator = .init("\u{000D}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 53"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{AC00}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 54"{
   var gc: GraphemeIterator = .init("\u{000D}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 55"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{AC01}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 56"{
   var gc: GraphemeIterator = .init("\u{000D}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 57"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 58"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 59"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{0915}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 60"{
   var gc: GraphemeIterator = .init("\u{000D}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 61"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{00A9}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 62"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 63"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{0020}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 64"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 65"{
   var gc: GraphemeIterator = .init("\u{000D}\u{0308}\u{0378}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 66"{
   var gc: GraphemeIterator = .init("\u{000A}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 67"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{000D}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 68"{
   var gc: GraphemeIterator = .init("\u{000A}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 69"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{000A}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 70"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 71"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{0000}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 72"{
   var gc: GraphemeIterator = .init("\u{000A}\u{094D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 73"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{094D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 74"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0300}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 75"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{0300}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 76"{
   var gc: GraphemeIterator = .init("\u{000A}\u{200C}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 77"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{200C}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 78"{
   var gc: GraphemeIterator = .init("\u{000A}\u{200D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 79"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{200D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 80"{
   var gc: GraphemeIterator = .init("\u{000A}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 81"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 82"{
   var gc: GraphemeIterator = .init("\u{000A}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 83"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{06DD}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 84"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0903}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 85"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{0903}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 86"{
   var gc: GraphemeIterator = .init("\u{000A}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 87"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{1100}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 88"{
   var gc: GraphemeIterator = .init("\u{000A}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 89"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{1160}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 90"{
   var gc: GraphemeIterator = .init("\u{000A}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 91"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{11A8}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 92"{
   var gc: GraphemeIterator = .init("\u{000A}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 93"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{AC00}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 94"{
   var gc: GraphemeIterator = .init("\u{000A}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 95"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{AC01}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 96"{
   var gc: GraphemeIterator = .init("\u{000A}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 97"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 98"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 99"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{0915}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 100"{
   var gc: GraphemeIterator = .init("\u{000A}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 101"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{00A9}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 102"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 103"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{0020}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 104"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 105"{
   var gc: GraphemeIterator = .init("\u{000A}\u{0308}\u{0378}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 106"{
   var gc: GraphemeIterator = .init("\u{0000}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 107"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{000D}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 108"{
   var gc: GraphemeIterator = .init("\u{0000}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 109"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{000A}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 110"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 111"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{0000}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 112"{
   var gc: GraphemeIterator = .init("\u{0000}\u{094D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 113"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{094D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 114"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0300}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 115"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{0300}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 116"{
   var gc: GraphemeIterator = .init("\u{0000}\u{200C}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 117"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{200C}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 118"{
   var gc: GraphemeIterator = .init("\u{0000}\u{200D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 119"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{200D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 120"{
   var gc: GraphemeIterator = .init("\u{0000}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 121"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 122"{
   var gc: GraphemeIterator = .init("\u{0000}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 123"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{06DD}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 124"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0903}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 125"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{0903}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 126"{
   var gc: GraphemeIterator = .init("\u{0000}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 127"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{1100}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 128"{
   var gc: GraphemeIterator = .init("\u{0000}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 129"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{1160}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 130"{
   var gc: GraphemeIterator = .init("\u{0000}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 131"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{11A8}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 132"{
   var gc: GraphemeIterator = .init("\u{0000}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 133"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{AC00}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 134"{
   var gc: GraphemeIterator = .init("\u{0000}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 135"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{AC01}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 136"{
   var gc: GraphemeIterator = .init("\u{0000}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 137"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 138"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 139"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{0915}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 140"{
   var gc: GraphemeIterator = .init("\u{0000}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 141"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{00A9}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 142"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 143"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{0020}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 144"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 145"{
   var gc: GraphemeIterator = .init("\u{0000}\u{0308}\u{0378}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 146"{
   var gc: GraphemeIterator = .init("\u{094D}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 147"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 148"{
   var gc: GraphemeIterator = .init("\u{094D}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 149"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 150"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 151"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 152"{
   var gc: GraphemeIterator = .init("\u{094D}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 153"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 154"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 155"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 156"{
   var gc: GraphemeIterator = .init("\u{094D}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 157"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 158"{
   var gc: GraphemeIterator = .init("\u{094D}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 159"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 160"{
   var gc: GraphemeIterator = .init("\u{094D}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 161"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 162"{
   var gc: GraphemeIterator = .init("\u{094D}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 163"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 164"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 165"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 166"{
   var gc: GraphemeIterator = .init("\u{094D}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 167"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 168"{
   var gc: GraphemeIterator = .init("\u{094D}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 169"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 170"{
   var gc: GraphemeIterator = .init("\u{094D}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 171"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 172"{
   var gc: GraphemeIterator = .init("\u{094D}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 173"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 174"{
   var gc: GraphemeIterator = .init("\u{094D}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 175"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 176"{
   var gc: GraphemeIterator = .init("\u{094D}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 177"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 178"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0915}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 179"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{0915}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 180"{
   var gc: GraphemeIterator = .init("\u{094D}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 181"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 182"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 183"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 184"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 185"{
   var gc: GraphemeIterator = .init("\u{094D}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 186"{
   var gc: GraphemeIterator = .init("\u{0300}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 187"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 188"{
   var gc: GraphemeIterator = .init("\u{0300}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 189"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 190"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 191"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 192"{
   var gc: GraphemeIterator = .init("\u{0300}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 193"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 194"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 195"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 196"{
   var gc: GraphemeIterator = .init("\u{0300}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 197"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 198"{
   var gc: GraphemeIterator = .init("\u{0300}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 199"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 200"{
   var gc: GraphemeIterator = .init("\u{0300}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 201"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 202"{
   var gc: GraphemeIterator = .init("\u{0300}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 203"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 204"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 205"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 206"{
   var gc: GraphemeIterator = .init("\u{0300}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 207"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 208"{
   var gc: GraphemeIterator = .init("\u{0300}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 209"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 210"{
   var gc: GraphemeIterator = .init("\u{0300}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 211"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 212"{
   var gc: GraphemeIterator = .init("\u{0300}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 213"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 214"{
   var gc: GraphemeIterator = .init("\u{0300}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 215"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 216"{
   var gc: GraphemeIterator = .init("\u{0300}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 217"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 218"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 219"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 220"{
   var gc: GraphemeIterator = .init("\u{0300}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 221"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 222"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 223"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 224"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 225"{
   var gc: GraphemeIterator = .init("\u{0300}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 226"{
   var gc: GraphemeIterator = .init("\u{200C}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 227"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 228"{
   var gc: GraphemeIterator = .init("\u{200C}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 229"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 230"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 231"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 232"{
   var gc: GraphemeIterator = .init("\u{200C}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 233"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 234"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 235"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 236"{
   var gc: GraphemeIterator = .init("\u{200C}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 237"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 238"{
   var gc: GraphemeIterator = .init("\u{200C}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 239"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 240"{
   var gc: GraphemeIterator = .init("\u{200C}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 241"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 242"{
   var gc: GraphemeIterator = .init("\u{200C}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 243"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 244"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 245"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 246"{
   var gc: GraphemeIterator = .init("\u{200C}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 247"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 248"{
   var gc: GraphemeIterator = .init("\u{200C}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 249"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 250"{
   var gc: GraphemeIterator = .init("\u{200C}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 251"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 252"{
   var gc: GraphemeIterator = .init("\u{200C}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 253"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 254"{
   var gc: GraphemeIterator = .init("\u{200C}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 255"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 256"{
   var gc: GraphemeIterator = .init("\u{200C}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 257"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 258"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 259"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 260"{
   var gc: GraphemeIterator = .init("\u{200C}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 261"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 262"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 263"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 264"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 265"{
   var gc: GraphemeIterator = .init("\u{200C}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 266"{
   var gc: GraphemeIterator = .init("\u{200D}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 267"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 268"{
   var gc: GraphemeIterator = .init("\u{200D}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 269"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 270"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 271"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 272"{
   var gc: GraphemeIterator = .init("\u{200D}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 273"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 274"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 275"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 276"{
   var gc: GraphemeIterator = .init("\u{200D}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 277"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 278"{
   var gc: GraphemeIterator = .init("\u{200D}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 279"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 280"{
   var gc: GraphemeIterator = .init("\u{200D}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 281"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 282"{
   var gc: GraphemeIterator = .init("\u{200D}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 283"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 284"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 285"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 286"{
   var gc: GraphemeIterator = .init("\u{200D}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 287"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 288"{
   var gc: GraphemeIterator = .init("\u{200D}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 289"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 290"{
   var gc: GraphemeIterator = .init("\u{200D}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 291"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 292"{
   var gc: GraphemeIterator = .init("\u{200D}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 293"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 294"{
   var gc: GraphemeIterator = .init("\u{200D}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 295"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 296"{
   var gc: GraphemeIterator = .init("\u{200D}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 297"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 298"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 299"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 300"{
   var gc: GraphemeIterator = .init("\u{200D}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 301"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 302"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 303"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 304"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 305"{
   var gc: GraphemeIterator = .init("\u{200D}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 306"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 307"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 308"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 309"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 310"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 311"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 312"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 313"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 314"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 315"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 316"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 317"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 318"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 319"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 320"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{1F1E6}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 321"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 322"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 323"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 324"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 325"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 326"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 327"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 328"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 329"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 330"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 331"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 332"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 333"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 334"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 335"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 336"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 337"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 338"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 339"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 340"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 341"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 342"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 343"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 344"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 345"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 346"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 347"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 348"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 349"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 350"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 351"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 352"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 353"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 354"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 355"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 356"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 357"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 358"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 359"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 360"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{1F1E6}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 361"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 362"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{06DD}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 363"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 364"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 365"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 366"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{1100}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 367"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 368"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{1160}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 369"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 370"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{11A8}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 371"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 372"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{AC00}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 373"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 374"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{AC01}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 375"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 376"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{1CF5}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 377"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 378"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0915}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 379"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 380"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{00A9}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 381"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 382"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0020}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 383"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 384"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0378}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 385"{
   var gc: GraphemeIterator = .init("\u{06DD}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 386"{
   var gc: GraphemeIterator = .init("\u{0903}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 387"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 388"{
   var gc: GraphemeIterator = .init("\u{0903}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 389"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 390"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 391"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 392"{
   var gc: GraphemeIterator = .init("\u{0903}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 393"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 394"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 395"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 396"{
   var gc: GraphemeIterator = .init("\u{0903}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 397"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 398"{
   var gc: GraphemeIterator = .init("\u{0903}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 399"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 400"{
   var gc: GraphemeIterator = .init("\u{0903}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 401"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 402"{
   var gc: GraphemeIterator = .init("\u{0903}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 403"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 404"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 405"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 406"{
   var gc: GraphemeIterator = .init("\u{0903}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 407"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 408"{
   var gc: GraphemeIterator = .init("\u{0903}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 409"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 410"{
   var gc: GraphemeIterator = .init("\u{0903}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 411"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 412"{
   var gc: GraphemeIterator = .init("\u{0903}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 413"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 414"{
   var gc: GraphemeIterator = .init("\u{0903}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 415"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 416"{
   var gc: GraphemeIterator = .init("\u{0903}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 417"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 418"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 419"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 420"{
   var gc: GraphemeIterator = .init("\u{0903}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 421"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 422"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 423"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 424"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 425"{
   var gc: GraphemeIterator = .init("\u{0903}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 426"{
   var gc: GraphemeIterator = .init("\u{1100}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 427"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 428"{
   var gc: GraphemeIterator = .init("\u{1100}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 429"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 430"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 431"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 432"{
   var gc: GraphemeIterator = .init("\u{1100}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 433"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 434"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 435"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 436"{
   var gc: GraphemeIterator = .init("\u{1100}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 437"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 438"{
   var gc: GraphemeIterator = .init("\u{1100}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 439"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 440"{
   var gc: GraphemeIterator = .init("\u{1100}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 441"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 442"{
   var gc: GraphemeIterator = .init("\u{1100}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 443"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 444"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 445"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 446"{
   var gc: GraphemeIterator = .init("\u{1100}\u{1100}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 447"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 448"{
   var gc: GraphemeIterator = .init("\u{1100}\u{1160}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 449"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 450"{
   var gc: GraphemeIterator = .init("\u{1100}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 451"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 452"{
   var gc: GraphemeIterator = .init("\u{1100}\u{AC00}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 453"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 454"{
   var gc: GraphemeIterator = .init("\u{1100}\u{AC01}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 455"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 456"{
   var gc: GraphemeIterator = .init("\u{1100}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 457"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 458"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 459"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 460"{
   var gc: GraphemeIterator = .init("\u{1100}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 461"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 462"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 463"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 464"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 465"{
   var gc: GraphemeIterator = .init("\u{1100}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 466"{
   var gc: GraphemeIterator = .init("\u{1160}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 467"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 468"{
   var gc: GraphemeIterator = .init("\u{1160}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 469"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 470"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 471"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 472"{
   var gc: GraphemeIterator = .init("\u{1160}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 473"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 474"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 475"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 476"{
   var gc: GraphemeIterator = .init("\u{1160}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 477"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 478"{
   var gc: GraphemeIterator = .init("\u{1160}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 479"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 480"{
   var gc: GraphemeIterator = .init("\u{1160}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 481"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 482"{
   var gc: GraphemeIterator = .init("\u{1160}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 483"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 484"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 485"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 486"{
   var gc: GraphemeIterator = .init("\u{1160}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 487"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 488"{
   var gc: GraphemeIterator = .init("\u{1160}\u{1160}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 489"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 490"{
   var gc: GraphemeIterator = .init("\u{1160}\u{11A8}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 491"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 492"{
   var gc: GraphemeIterator = .init("\u{1160}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 493"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 494"{
   var gc: GraphemeIterator = .init("\u{1160}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 495"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 496"{
   var gc: GraphemeIterator = .init("\u{1160}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 497"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 498"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 499"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 500"{
   var gc: GraphemeIterator = .init("\u{1160}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 501"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 502"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 503"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 504"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 505"{
   var gc: GraphemeIterator = .init("\u{1160}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 506"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 507"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 508"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 509"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 510"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 511"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 512"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 513"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 514"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 515"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 516"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 517"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 518"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 519"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 520"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 521"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 522"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 523"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 524"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 525"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 526"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 527"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 528"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 529"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 530"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{11A8}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 531"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 532"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 533"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 534"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 535"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 536"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 537"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 538"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 539"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 540"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 541"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 542"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 543"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 544"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 545"{
   var gc: GraphemeIterator = .init("\u{11A8}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 546"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 547"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 548"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 549"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 550"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 551"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 552"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 553"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 554"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 555"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 556"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 557"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 558"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 559"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 560"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 561"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 562"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 563"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 564"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 565"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 566"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 567"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 568"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{1160}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 569"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 570"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{11A8}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 571"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 572"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 573"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 574"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 575"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 576"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 577"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 578"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 579"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 580"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 581"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 582"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 583"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 584"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 585"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 586"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 587"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 588"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 589"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 590"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 591"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 592"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 593"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 594"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 595"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 596"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 597"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 598"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 599"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 600"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 601"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 602"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 603"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 604"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 605"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 606"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 607"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 608"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 609"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 610"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{11A8}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 611"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 612"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 613"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 614"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 615"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 616"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 617"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 618"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 619"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 620"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 621"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 622"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 623"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 624"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 625"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 626"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 627"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 628"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 629"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 630"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 631"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 632"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 633"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 634"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 635"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 636"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 637"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 638"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 639"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 640"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 641"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 642"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 643"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 644"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 645"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 646"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 647"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 648"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 649"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 650"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 651"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 652"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 653"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 654"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 655"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 656"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 657"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 658"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0915}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 659"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{0915}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 660"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 661"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 662"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 663"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 664"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 665"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 666"{
   var gc: GraphemeIterator = .init("\u{0915}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 667"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 668"{
   var gc: GraphemeIterator = .init("\u{0915}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 669"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 670"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 671"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 672"{
   var gc: GraphemeIterator = .init("\u{0915}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 673"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 674"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 675"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 676"{
   var gc: GraphemeIterator = .init("\u{0915}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 677"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 678"{
   var gc: GraphemeIterator = .init("\u{0915}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 679"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 680"{
   var gc: GraphemeIterator = .init("\u{0915}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 681"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 682"{
   var gc: GraphemeIterator = .init("\u{0915}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 683"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 684"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 685"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 686"{
   var gc: GraphemeIterator = .init("\u{0915}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 687"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 688"{
   var gc: GraphemeIterator = .init("\u{0915}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 689"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 690"{
   var gc: GraphemeIterator = .init("\u{0915}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 691"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 692"{
   var gc: GraphemeIterator = .init("\u{0915}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 693"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 694"{
   var gc: GraphemeIterator = .init("\u{0915}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 695"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 696"{
   var gc: GraphemeIterator = .init("\u{0915}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 697"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 698"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 699"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 700"{
   var gc: GraphemeIterator = .init("\u{0915}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 701"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 702"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 703"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 704"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 705"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 706"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 707"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 708"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 709"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 710"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 711"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 712"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 713"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 714"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 715"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 716"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 717"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 718"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 719"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 720"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 721"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 722"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 723"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 724"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 725"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 726"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 727"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 728"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 729"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 730"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 731"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 732"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 733"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 734"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 735"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 736"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 737"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 738"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 739"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 740"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 741"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 742"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 743"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 744"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 745"{
   var gc: GraphemeIterator = .init("\u{00A9}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 746"{
   var gc: GraphemeIterator = .init("\u{0020}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 747"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 748"{
   var gc: GraphemeIterator = .init("\u{0020}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 749"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 750"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 751"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 752"{
   var gc: GraphemeIterator = .init("\u{0020}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 753"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 754"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 755"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 756"{
   var gc: GraphemeIterator = .init("\u{0020}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 757"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 758"{
   var gc: GraphemeIterator = .init("\u{0020}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 759"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 760"{
   var gc: GraphemeIterator = .init("\u{0020}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 761"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 762"{
   var gc: GraphemeIterator = .init("\u{0020}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 763"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 764"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 765"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 766"{
   var gc: GraphemeIterator = .init("\u{0020}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 767"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 768"{
   var gc: GraphemeIterator = .init("\u{0020}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 769"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 770"{
   var gc: GraphemeIterator = .init("\u{0020}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 771"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 772"{
   var gc: GraphemeIterator = .init("\u{0020}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 773"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 774"{
   var gc: GraphemeIterator = .init("\u{0020}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 775"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 776"{
   var gc: GraphemeIterator = .init("\u{0020}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 777"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 778"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 779"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 780"{
   var gc: GraphemeIterator = .init("\u{0020}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 781"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 782"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 783"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 784"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 785"{
   var gc: GraphemeIterator = .init("\u{0020}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 786"{
   var gc: GraphemeIterator = .init("\u{0378}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 787"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{000D}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 788"{
   var gc: GraphemeIterator = .init("\u{0378}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 789"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{000A}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 790"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 791"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{0000}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 792"{
   var gc: GraphemeIterator = .init("\u{0378}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 793"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{094D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 794"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 795"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{0300}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 796"{
   var gc: GraphemeIterator = .init("\u{0378}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 797"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{200C}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 798"{
   var gc: GraphemeIterator = .init("\u{0378}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 799"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 800"{
   var gc: GraphemeIterator = .init("\u{0378}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 801"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{1F1E6}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 802"{
   var gc: GraphemeIterator = .init("\u{0378}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 803"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{06DD}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 804"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 805"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{0903}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 806"{
   var gc: GraphemeIterator = .init("\u{0378}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 807"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 808"{
   var gc: GraphemeIterator = .init("\u{0378}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 809"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{1160}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 810"{
   var gc: GraphemeIterator = .init("\u{0378}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 811"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{11A8}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 812"{
   var gc: GraphemeIterator = .init("\u{0378}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 813"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{AC00}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 814"{
   var gc: GraphemeIterator = .init("\u{0378}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 815"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{AC01}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 816"{
   var gc: GraphemeIterator = .init("\u{0378}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 817"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{1CF5}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 818"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 819"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{0915}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 820"{
   var gc: GraphemeIterator = .init("\u{0378}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 821"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{00A9}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 822"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 823"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 824"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 825"{
   var gc: GraphemeIterator = .init("\u{0378}\u{0308}\u{0378}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 826"{
   var gc: GraphemeIterator = .init("\u{000D}\u{000A}\u{0061}\u{000A}\u{0308}");
   try std.testing.expectEqual(4, gc.count());
}
test "Test 827"{
   var gc: GraphemeIterator = .init("\u{0061}\u{0308}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 828"{
   var gc: GraphemeIterator = .init("\u{0020}\u{200D}\u{0646}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 829"{
   var gc: GraphemeIterator = .init("\u{0646}\u{200D}\u{0020}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 830"{
   var gc: GraphemeIterator = .init("\u{1100}\u{1100}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 831"{
   var gc: GraphemeIterator = .init("\u{AC00}\u{11A8}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 832"{
   var gc: GraphemeIterator = .init("\u{AC01}\u{11A8}\u{1100}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 833"{
   var gc: GraphemeIterator = .init("\u{1F1E6}\u{1F1E7}\u{1F1E8}\u{0062}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 834"{
   var gc: GraphemeIterator = .init("\u{0061}\u{1F1E6}\u{1F1E7}\u{1F1E8}\u{0062}");
   try std.testing.expectEqual(4, gc.count());
}
test "Test 835"{
   var gc: GraphemeIterator = .init("\u{0061}\u{1F1E6}\u{1F1E7}\u{200D}\u{1F1E8}\u{0062}");
   try std.testing.expectEqual(4, gc.count());
}
test "Test 836"{
   var gc: GraphemeIterator = .init("\u{0061}\u{1F1E6}\u{200D}\u{1F1E7}\u{1F1E8}\u{0062}");
   try std.testing.expectEqual(4, gc.count());
}
test "Test 837"{
   var gc: GraphemeIterator = .init("\u{0061}\u{1F1E6}\u{1F1E7}\u{1F1E8}\u{1F1E9}\u{0062}");
   try std.testing.expectEqual(4, gc.count());
}
test "Test 838"{
   var gc: GraphemeIterator = .init("\u{0061}\u{200D}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 839"{
   var gc: GraphemeIterator = .init("\u{0061}\u{0308}\u{0062}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 840"{
   var gc: GraphemeIterator = .init("\u{0061}\u{0903}\u{0062}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 841"{
   var gc: GraphemeIterator = .init("\u{0061}\u{0600}\u{0062}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 842"{
   var gc: GraphemeIterator = .init("\u{1F476}\u{1F3FF}\u{1F476}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 843"{
   var gc: GraphemeIterator = .init("\u{0061}\u{1F3FF}\u{1F476}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 844"{
   var gc: GraphemeIterator = .init("\u{0061}\u{1F3FF}\u{1F476}\u{200D}\u{1F6D1}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 845"{
   var gc: GraphemeIterator = .init("\u{1F476}\u{1F3FF}\u{0308}\u{200D}\u{1F476}\u{1F3FF}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 846"{
   var gc: GraphemeIterator = .init("\u{1F6D1}\u{200D}\u{1F6D1}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 847"{
   var gc: GraphemeIterator = .init("\u{0061}\u{200D}\u{1F6D1}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 848"{
   var gc: GraphemeIterator = .init("\u{2701}\u{200D}\u{2701}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 849"{
   var gc: GraphemeIterator = .init("\u{0061}\u{200D}\u{2701}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 850"{
   var gc: GraphemeIterator = .init("\u{0915}\u{0924}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 851"{
   var gc: GraphemeIterator = .init("\u{0915}\u{094D}\u{0924}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 852"{
   var gc: GraphemeIterator = .init("\u{0915}\u{094D}\u{094D}\u{0924}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 853"{
   var gc: GraphemeIterator = .init("\u{0915}\u{094D}\u{200D}\u{0924}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 854"{
   var gc: GraphemeIterator = .init("\u{0915}\u{093C}\u{200D}\u{094D}\u{0924}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 855"{
   var gc: GraphemeIterator = .init("\u{0915}\u{093C}\u{094D}\u{200D}\u{0924}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 856"{
   var gc: GraphemeIterator = .init("\u{0915}\u{094D}\u{0924}\u{094D}\u{092F}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 857"{
   var gc: GraphemeIterator = .init("\u{0915}\u{094D}\u{0061}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 858"{
   var gc: GraphemeIterator = .init("\u{0061}\u{094D}\u{0924}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 859"{
   var gc: GraphemeIterator = .init("\u{003F}\u{094D}\u{0924}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 860"{
   var gc: GraphemeIterator = .init("\u{0915}\u{094D}\u{094D}\u{0924}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 861"{
   var gc: GraphemeIterator = .init("\u{0AB8}\u{0AFB}\u{0ACD}\u{0AB8}\u{0AFB}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 862"{
   var gc: GraphemeIterator = .init("\u{1019}\u{1039}\u{1018}\u{102C}\u{1037}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 863"{
   var gc: GraphemeIterator = .init("\u{1004}\u{103A}\u{1039}\u{1011}\u{1039}\u{1011}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 864"{
   var gc: GraphemeIterator = .init("\u{1B12}\u{1B01}\u{1B32}\u{1B44}\u{1B2F}\u{1B32}\u{1B44}\u{1B22}\u{1B44}\u{1B2C}\u{1B32}\u{1B44}\u{1B22}\u{1B38}");
   try std.testing.expectEqual(4, gc.count());
}
test "Test 865"{
   var gc: GraphemeIterator = .init("\u{179F}\u{17D2}\u{178F}\u{17D2}\u{179A}\u{17B8}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 866"{
   var gc: GraphemeIterator = .init("\u{1B26}\u{1B17}\u{1B44}\u{1B13}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 867"{
   var gc: GraphemeIterator = .init("\u{1B27}\u{1B13}\u{1B44}\u{1B0B}\u{1B0B}\u{1B04}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 868"{
   var gc: GraphemeIterator = .init("\u{1795}\u{17D2}\u{17AF}\u{1798}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 869"{
   var gc: GraphemeIterator = .init("\u{17A0}\u{17D2}\u{17AB}\u{1791}\u{17D0}\u{1799}");
   try std.testing.expectEqual(3, gc.count());
}
test "Test 870"{
   var gc: GraphemeIterator = .init("\u{1B05}\u{1B44}\u{1B33}\u{1B03}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 871"{
   var gc: GraphemeIterator = .init("\u{0CF1}\u{0C95}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 872"{
   var gc: GraphemeIterator = .init("\u{0CF2}\u{0CAB}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 873"{
   var gc: GraphemeIterator = .init("\u{0CF1}\u{0C95}\u{0CBF}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 874"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{0995}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 875"{
   var gc: GraphemeIterator = .init("\u{1CF6}\u{09AA}");
   try std.testing.expectEqual(1, gc.count());
}
test "Test 876"{
   var gc: GraphemeIterator = .init("\u{1CF5}\u{200C}\u{0995}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 877"{
   var gc: GraphemeIterator = .init("\u{1CF6}\u{200C}\u{09AA}");
   try std.testing.expectEqual(2, gc.count());
}
test "Test 878"{
   var gc: GraphemeIterator = .init("\u{11A3A}\u{11A0B}");
   try std.testing.expectEqual(1, gc.count());
}
//END_EAT
