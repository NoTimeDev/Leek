const std = @import("std");
pub const segmentation = @import("segmentation.zig");

test {
    std.testing.refAllDecls(@This());
}
