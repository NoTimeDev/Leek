pub const unicode = @import("unicode/root.zig");
pub const rope = @import("rope/root.zig");

// This is the simplest form of error handling to exist!
pub var err: ?[]const u8 = null;

pub inline fn expect(msg: []const u8, result: anytype) @TypeOf(result){
    return result catch |e|{
        err = msg;
        return e;
    };
}
test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
