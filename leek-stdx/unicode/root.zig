//! This provides 1. segmentation and 2. width
//! segmentation gives tools to dectect the boundaries of graphemes
//! width gives tools to dectect the terminal width of graphemes

pub const segmentation = @import("segmentation.zig");
pub const width = @import("width.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
