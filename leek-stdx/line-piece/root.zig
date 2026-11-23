const std = @import("std");

fn Link(comptime T: type) type {
    return struct {
        const this = @This();
        next: ?*this,
        prev: ?*this,
        value: T,
    };
}

fn LinkedList(comptime T: type) type {
    return struct {
        const LinkType = Link(T);
        root: *LinkType,
        end: *LinkType,
        len: usize,

        const this = @This();
        pub fn init(allocator: std.mem.Allocator, value: T) !this {
            const node = try allocator.create(LinkType);
            node.value = value;
            node.next = null;
            node.prev = null;
            return .{
                .root = node,
                .end = node,
                .len = 1,
            };
        }

        pub fn index(self: *this, idx: usize) *T {
            var curr: ?*LinkType = self.root;
            var p = idx;
            while (p != 0) {
                const c = curr;
                curr = (c orelse unreachable).next;
                p -= 1;
            }
            return &(curr orelse unreachable).value;
        }

        pub fn insert(self: *this, allocator: std.mem.Allocator, pos: usize, value: T) !void {
            if (pos == self.len) {
                try self.push(allocator, value);
                return;
            }
            self.len += 1;
            var curr = self.root;
            var p = pos;
            while (p != 0) {
                const c = curr;
                curr = c.next orelse return error.InvalidIndex;
                p -= 1;
            }
            const node = try allocator.create(LinkType);
            node.value = value;
            node.next = null;
            node.prev = null;
            if (curr.prev) |prev| {
                prev.next = node;
                node.prev = prev;
            } else {
                self.root = node;
            }
            curr.prev = node;
            node.next = curr;
        }

        pub fn push(self: *this, allocator: std.mem.Allocator, value: T) !void {
            self.len += 1;
            const node = try allocator.create(LinkType);
            node.value = value;
            node.next = null;
            node.prev = null;
            self.end.next = node;
            node.prev = self.end;
            self.end = node;
        }

        pub fn deinit(self: *this, allocator: std.mem.Allocator) void {
            var curr: ?*LinkType = self.end;
            while (curr) |c| {
                curr = c.prev;
                allocator.destroy(c);
            }
        }
    };
}

const Piece = struct {
    buffer: enum(u1) { additional, original },
    start: usize,
    end: usize,
};

pub const Line = struct { pieces: LinkedList(Piece), len: usize };

pub const Slice = struct {
    start: usize,
    end: usize,
    pos: usize,
    root: *Link(Piece),
};

pub const LinePiece = struct {
    original_buffer: []const u8,
    add_buffer: std.ArrayList(u8),
    lines: LinkedList(Line),

    pub fn init(allocator: std.mem.Allocator, str: []const u8) !LinePiece {
        return .{ .original_buffer = str, .add_buffer = .empty, .lines = try .init(allocator, .{ .pieces = try .init(allocator, .{
            .buffer = .original,
            .start = 0,
            .end = str.len,
        }), .len = str.len }) };
    }

    pub fn insert_line(self: *LinePiece, allocator: std.mem.Allocator, line: usize, contents: []const u8) !void {
        const start = self.add_buffer.items.len;
        try self.add_buffer.appendSlice(allocator, contents);

        try self.lines.insert(allocator, line, Line{ .pieces = try .init(allocator, .{
            .buffer = .additional,
            .start = start,
            .end = contents.len,
        }), .len = contents.len });
    }

    pub fn insert(self: *LinePiece, allocator: std.mem.Allocator, line: usize, start: usize, str: []const u8) !void {
        const buf_start = self.add_buffer.items.len;
        try self.add_buffer.appendSlice(allocator, str);

        const line_list = self.lines.index(line);
        var curr = line_list.pieces.root;
        var pos: usize = 0;
        var link_pos: usize = 0;
        while (pos < start) {
            const len = curr.value.end - curr.value.start;
            if (pos + len >= start) break;
            pos += len;
            curr = curr.next orelse unreachable;
            link_pos += 1;
        }
        const chunk = &curr.value;
        if (start - pos == 0) {
            try line_list.pieces.insert(allocator, link_pos, .{
                .start = buf_start,
                .end = self.add_buffer.items.len,
                .buffer = .additional,
            });
        } else if (start - pos == chunk.end) {
            try line_list.pieces.insert(allocator, link_pos + 1, .{
                .start = buf_start,
                .end = self.add_buffer.items.len,
                .buffer = .additional,
            });
        } else {
            const offset = start - pos;
            const split = chunk.start + offset;
            const old_end = chunk.end;

            chunk.end = split;

            try line_list.pieces.insert(allocator, link_pos + 1, .{
                .start = buf_start,
                .end = self.add_buffer.items.len,
                .buffer = .additional,
            });

            try line_list.pieces.insert(allocator, link_pos + 2, .{
                .start = split,
                .end = old_end,
                .buffer = chunk.buffer,
            });
        }
        line_list.len += str.len;
    }

    pub fn deinit(self: *LinePiece, allocator: std.mem.Allocator) void {
        self.add_buffer.deinit(allocator);
        var curr: ?*Link(Line) = self.lines.root;
        while (curr) |node| {
            node.value.pieces.deinit(allocator);
            curr = node.next;
        }
        self.lines.deinit(allocator);
    }
};
