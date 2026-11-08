pub const unicode = @import("unicode/root.zig");
pub const rope = @import("rope/root.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
