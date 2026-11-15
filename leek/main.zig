pub const core = @import("core");
pub const tui = @import("tui");
const std = @import("std");
const builtin = @import("builtin");

var dbg: std.heap.DebugAllocator(.{}) = .init;
const allocator = if (builtin.mode == .debug)
    dbg.allocator()
else
    std.heap.smp_allocator;

pub fn main() void {}
