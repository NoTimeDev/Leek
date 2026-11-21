pub const stdx = @import("stdx");
pub const tui = @import("tui");
pub const termy = @import("termy");

const std = @import("std");
const builtin = @import("builtin");

pub var dbg: if (builtin.mode == .debug) std.heap.SafeAllocator else void = if (builtin.mode == .debug) .init(std.heap.smp_allocator, .{ .stack_trace_frames = 20 }) else {};
pub const allocator = if (builtin.mode == .debug)
    dbg.allocator()
else
    std.heap.smp_allocator;
