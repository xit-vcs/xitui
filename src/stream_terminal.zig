//! a Terminal-shaped backend driven externally by a session driver

const std = @import("std");
const inp = @import("./input.zig");
const term = @import("./terminal.zig");
const Size = @import("./layout.zig").Size;

pub const StreamTerminal = struct {
    writer: *std.Io.Writer,
    parser: term.EscapeParser,
    render_state: term.RenderState,
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
            .writer = writer,
            .parser = parser,
            .render_state = term.RenderState.init(allocator),
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
        self.render_state.deinit();
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
    // accumulate in the parser's queue, drained by repeated popKey calls. an
    // escape sequence split across two data frames resolves once the rest
    // arrives, so bytes may be fed in arbitrary chunks.
    pub fn writeBytes(self: *StreamTerminal, bytes: []const u8) !void {
        try self.parser.queueBytes(bytes);
    }

    // report a held-back ESC as the escape key. a lone ESC is ambiguous until
    // the next byte arrives, since it may open a sequence carried in the next
    // frame, so a driver should call this once input has gone idle (~25 ms is
    // the convention) or pressing Escape waits on the next keystroke.
    pub fn flushEscape(self: *StreamTerminal) !void {
        try self.parser.flushEscape();
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

    pub fn render(self: *StreamTerminal, root_widget: anytype) !bool {
        return try term.renderToWriter(
            self.writer,
            &self.render_state,
            root_widget,
            self.size,
        );
    }
};
