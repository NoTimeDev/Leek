pub const unicode = @import("unicode/root.zig");
pub const line_piece = @import("line-piece/root.zig");

// This is the simplest form of error handling to exist!
pub var err: ?[]const u8 = null;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
