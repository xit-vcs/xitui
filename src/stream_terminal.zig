//! a Terminal-shaped backend driven externally by a session driver

const std = @import("std");
const inp = @import("./input.zig");
const grd = @import("./grid.zig");
const term = @import("./terminal.zig");
const Size = @import("./layout.zig").Size;

pub const StreamTerminal = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    parser: term.EscapeParser,
    size: Size,
    resized: bool,
    quit: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        initial_size: Size,
    ) !StreamTerminal {
        var parser = try term.EscapeParser.init(allocator);
        errdefer parser.deinit();

        var self = StreamTerminal{
            .allocator = allocator,
            .writer = writer,
            .parser = parser,
            .size = initial_size,
            .resized = false,
            .quit = false,
        };

        try term.hideCursor(self.writer);
        try term.enterAlt(self.writer);
        try term.clearStyle(self.writer);
        try term.enableMouse(self.writer);
        try self.writer.flush();

        return self;
    }

    pub fn deinit(self: *StreamTerminal) void {
        // best-effort tear-down so we don't leave the remote terminal in
        // alt-screen or with mouse tracking on if the session ends abruptly
        term.disableMouse(self.writer) catch {};
        term.clearStyle(self.writer) catch {};
        term.leaveAlt(self.writer) catch {};
        term.showCursor(self.writer) catch {};
        term.attributeReset(self.writer) catch {};
        self.writer.flush() catch {};

        self.parser.deinit();
    }

    pub fn shouldQuit(self: *const StreamTerminal) bool {
        return self.quit;
    }

    pub fn requestQuit(self: *StreamTerminal) void {
        self.quit = true;
    }

    pub fn pushResize(self: *StreamTerminal, new_size: Size) void {
        self.size = new_size;
        self.resized = true;
    }

    pub fn getSize(self: *const StreamTerminal) Size {
        return self.size;
    }

    // push raw user-input bytes through the escape parser. resulting keys
    // accumulate in the parser's queue, drained by repeated popKey calls.
    // unlike the tty backend we don't clear scratch between calls — a
    // partial escape sequence split across two data frames should still
    // resolve once the rest arrives.
    pub fn writeBytes(self: *StreamTerminal, bytes: []const u8) !void {
        // EscapeParser.writeBytes returns the first key inline and queues
        // the rest, but we want every key in the queue so popKey can drain
        // them in arrival order. push the inline return back to the head.
        if (try self.parser.writeBytes(bytes)) |first| {
            try self.parser.prepend(first);
        }
    }

    // pop the next decoded input event: a queued key, a pending resize, or
    // null if there's nothing to deliver right now.
    pub fn popKey(self: *StreamTerminal) ?inp.Key {
        if (self.resized) {
            self.resized = false;
            return .{ .event = .resize };
        }
        return self.parser.popQueued();
    }

    pub fn render(self: *StreamTerminal, root_widget: anytype, last_grid: *grd.Grid, last_size: *Size) !bool {
        return try term.renderToWriter(
            self.writer,
            self.allocator,
            root_widget,
            last_grid,
            last_size,
            self.size,
        );
    }
};
