const std = @import("std");
const builtin = @import("builtin");
const leek = @import("leek");

const App = struct {
    tty: leek.termy.Tty = undefined,
    termy_buffer: [1024]u8 = undefined,
    tui: leek.tui.Tui = undefined,

    pub fn init(self: *App, io: std.Io) !void{
        self.tty = .init(io, try leek.termy.sysOut(), &self.termy_buffer, try leek.termy.sysIn());
        self.tui = .init(&self.tty, leek.allocator);
        try self.tui.enter();
    }

    pub fn deinit(self: *App) void{
        self.tui.deinit();
    }

    pub fn run(self: *App) !void{
        try std.Io.sleep(self.tty.io, .fromSeconds(2), .awake);
    }
};

pub fn main(init: std.process.Init) void {
    var app: App = undefined;
    app.init(init.io) catch {
        if(leek.core.err)|e|{
            std.debug.print("Leek Failed: {s}\n", .{e});
        }
        if(builtin.mode == .debug){
            std.debug.dumpCurrentStackTrace(.{});
        }
        std.process.exit(1);
    };
    app.run() catch {
        app.deinit();
        if(leek.core.err)|e|{
            std.debug.print("Leek Failed: {s}\n", .{e});
        }
        if(builtin.mode == .debug){
            std.debug.dumpCurrentStackTrace(.{});
        }
        std.process.exit(1);
    };

    app.deinit();
    if(builtin.mode == .debug){
        const leaked = leek.dbg.deinit();
        if(leaked != 0){
            std.debug.print("{} allocations leaked!\n", .{leaked});
            std.process.exit(1);
        }
    }
}
