//! This provides 1. segmentation and 2. width
//! segmentation gives tools to dectect the boundaries of graphemes
//! width gives tools to dectect the terminal width of graphemes

const std = @import("std");
pub const segmentation = @import("segmentation.zig");

test {
    std.testing.refAllDecls(@This());
}
