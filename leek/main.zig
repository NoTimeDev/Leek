const std = @import("std");
const builtin = @import("builtin");
const leek = @import("leek");
const stdx = leek.stdx;

const App = struct {
    tty: leek.termy.Tty,
    input: leek.termy.Input,
    termy_buffer: [1024]u8,
    tui: leek.tui.Tui,
    running: bool,

    pub fn init(self: *App, io: std.Io) !void {
        self.tty = .init(io, try leek.termy.sysOut(), &self.termy_buffer, try leek.termy.sysIn());
        self.tui = try .init(&self.tty, leek.allocator);
        self.input = .init(&self.tty);
        self.running = true;
    }

    pub fn deinit(self: *App) void {
        self.tui.deinit();
    }

    pub fn update(self: *App, event: ?leek.termy.event.Event) !void {
        if (event) |ev| {
            switch (ev) {
                .Key => |key| {
                    switch (key.code) {
                        .Esc => {
                            self.running = false;
                        },
                        else => {},
                    }
                },
                .Resize => |s| {
                    try self.tui.resize(.{ .x = 0, .y = 0, .width = s.columns, .height = s.rows });
                },
                else => {},
            }
        }
    }

    pub fn render(self: *App) !void {
        try self.tui.render(leek.tui.widget.block.Block{
            .style = .Retro,
            .positions = .ALL,
        }, .{
            .x = 0,
            .y = 0,
            .width = 5,
            .height = 5,
        });
        try self.tui.draw();
    }

    pub fn run(self: *App) !void {
        while (self.running) {
            try self.update(if (self.input.poll(.fromMilliseconds(20)) catch |err| {
                stdx.err = "Failed to poll event";
                return err;
            })
                self.input.read() catch |err| {
                    stdx.err = "Failed to read event";
                    return err;
                }
            else
                null);
            try self.render();
        }
    }
};

pub fn main(init: std.process.Init) void {
    var app: App = undefined;
    app.init(init.io) catch {
        if (leek.stdx.err) |e| {
            std.debug.print("Leek Failed: {s}\n", .{e});
        }
        if (builtin.mode == .debug) {
            std.debug.dumpCurrentStackTrace(.{});
        }
        std.process.exit(1);
    };
    app.run() catch {
        app.deinit();
        if (leek.stdx.err) |e| {
            std.debug.print("Leek Failed: {s}\n", .{e});
        }
        if (builtin.mode == .debug) {
            std.debug.dumpCurrentStackTrace(.{});
        }
        std.process.exit(1);
    };

    app.deinit();
    if (builtin.mode == .debug) {
        const leaked = leek.dbg.deinit();
        if (leaked != 0) {
            std.debug.print("{} allocations leaked!\n", .{leaked});
            std.process.exit(1);
        }
    }
}
