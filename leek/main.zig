const std = @import("std");
const builtin = @import("builtin");
const leek = @import("leek");
const stdx = leek.stdx;
const tui = leek.tui;

const App = struct {
    tty: leek.termy.Tty,
    input: leek.termy.Input,
    termy_buffer: [1024]u8,
    tui: tui.Tui,
    running: bool,
    line: usize = 0,

    pub fn init(self: *App, io: std.Io) !void {
        self.tty = .init(io, try leek.termy.sysOut(), &self.termy_buffer, try leek.termy.sysIn());
        self.tui = try .init(&self.tty, leek.allocator);
        self.input = .init(&self.tty);
        self.running = true;
        self.line = 0;
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
        const block: tui.widget.Block = .{
            .style = .Rounded,
            .bg = .{ .Rgb = .{
                .b = 8,
                .g = 8,
                .r = 8,
            } },
            .positions = .ALL,
        };
        try self.tui.render(block, self.tui.size);
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

pub fn main(init: std.process.Init) !void {
    //     var app: App = undefined;
    //     app.init(init.io) catch {
    //         if (leek.stdx.err) |e| {
    //             std.debug.print("Leek Failed: {s}\n", .{e});
    //         }
    //         if (builtin.mode == .debug) {
    //             std.debug.dumpCurrentStackTrace(.{});
    //         }
    //         std.process.exit(1);
    //     };
    //     app.run() catch {
    //         app.deinit();
    //         if (leek.stdx.err) |e| {
    //             std.debug.print("Leek Failed: {s}\n", .{e});
    //         }
    //         if (builtin.mode == .debug) {
    //             std.debug.dumpCurrentStackTrace(.{});
    //         }
    //         std.process.exit(1);
    //     };

    //     app.deinit();
    //     if (builtin.mode == .debug) {
    //         const leaked = leek.dbg.deinit();
    //         if (leaked != 0) {
    //             std.debug.print("{} allocations leaked!\n", .{leaked});
    //             std.process.exit(1);
    //         }
    //     }

    var piece: stdx.line_piece.LinePiece = try .init(init.gpa, "This should come after!");
    defer piece.deinit(init.gpa);
    try piece.insert(init.gpa, 0, 0, "AnotherLine ");
    try piece.insert(init.gpa, 0, 7, " Other ");
    try piece.insert(init.gpa, 0, 7, "yster fa");

    var curr_p: ?@TypeOf(piece.lines.index(0).pieces.root) = piece.lines.index(0).pieces.root;
    while (curr_p) |node| {
        switch (node.value.buffer) {
            .additional => {
                std.debug.print("{s}", .{piece.add_buffer.items[node.value.start..node.value.end]});
            },
            .original => {
                std.debug.print("{s}", .{piece.original_buffer[node.value.start..node.value.end]});
            },
        }
        curr_p = node.next;
    }
    std.debug.print("\n", .{});
}
