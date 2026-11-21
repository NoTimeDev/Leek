//! This module provides abstractions over termy-zig to make building tui easier
pub const termy = @import("termy");
pub const stdx = @import("stdx");

pub const tui = @import("tui.zig");
pub const Tui = tui.Tui;
const std = @import("std");

/// A rectangled used as the base in all
pub const Rect = struct {
    x: u16,
    y: u16,
};
