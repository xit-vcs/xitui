const std = @import("std");
const xitui = @import("xitui");
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const StreamTerminal = xitui.stream_terminal.StreamTerminal;

pub const Widget = union(enum) {
    text: wgt.Text(Widget),
    box: wgt.Box(Widget),
    text_box: wgt.TextBox(Widget),
    scroll: wgt.Scroll(Widget),

    pub fn deinit(self: *Widget) void {
        switch (self.*) {
            inline else => |*case| case.deinit(),
        }
    }

    pub fn build(self: *Widget, constraint: layout.Constraint, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.build(constraint, root_focus),
        }
    }

    pub fn input(self: *Widget, key: inp.Key, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.input(key, root_focus),
        }
    }

    pub fn clearGrid(self: *Widget) void {
        switch (self.*) {
            inline else => |*case| case.clearGrid(),
        }
    }

    pub fn getGrid(self: Widget) ?Grid {
        switch (self) {
            inline else => |*case| return case.getGrid(),
        }
    }

    pub fn getFocus(self: *Widget) *Focus {
        switch (self.*) {
            inline else => |*case| return case.getFocus(),
        }
    }
};

test "text box" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_box = try wgt.TextBox(Widget).init(allocator, "Hello, world!", .{ .border_style = .single, .wrap_kind = .none }) };
    defer widget.deinit();

    try widget.build(.{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = null, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);

    try std.testing.expectEqualStrings(
        \\┌─────────────┐
        \\│Hello, world!│
        \\└─────────────┘
    , str);
}

test "text box with wrapping" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_box = try wgt.TextBox(Widget).init(allocator, "Hello, world!\nGöödbye, world!", .{ .border_style = .single, .wrap_kind = .char }) };
    defer widget.deinit();

    try widget.build(.{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 10, .height = null },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\┌────────┐
            \\│Hello, w│
            \\│orld!   │
            \\│Göödbye,│
            \\│ world! │
            \\└────────┘
        , str);
    }

    try widget.build(.{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 12, .height = null },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\┌──────────┐
            \\│Hello, wor│
            \\│ld!       │
            \\│Göödbye, w│
            \\│orld!     │
            \\└──────────┘
        , str);
    }

    try widget.build(.{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 12, .height = null },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\┌──────────┐
            \\│Hello, wor│
            \\│ld!       │
            \\│Göödbye, w│
            \\│orld!     │
            \\└──────────┘
        , str);
    }
}

test "StreamTerminal parses a CSI arrow key" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    try terminal.writeBytes("\x1B[A");
    try std.testing.expectEqual(@as(?inp.Key, .arrow_up), terminal.popKey());
}

test "StreamTerminal parses codepoints and queues extras" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    // arrow up followed by 'q' in a single byte feed — the parser returns
    // the arrow first and queues the codepoint for the next pop.
    try terminal.writeBytes("\x1B[Aq");
    try std.testing.expectEqual(@as(?inp.Key, .arrow_up), terminal.popKey());
    const second = terminal.popKey();
    try std.testing.expect(second != null);
    try std.testing.expectEqual(@as(u21, 'q'), second.?.codepoint);
}

test "StreamTerminal resize injection" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    terminal.pushResize(.{ .width = 100, .height = 30 });

    try std.testing.expectEqual(@as(?inp.Key, .{ .event = .resize }), terminal.popKey());
    try std.testing.expectEqual(@as(usize, 100), terminal.getSize().width);
    try std.testing.expectEqual(@as(usize, 30), terminal.getSize().height);
}

test "StreamTerminal quit injection" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    try std.testing.expect(!terminal.shouldQuit());
    terminal.requestQuit();
    try std.testing.expect(terminal.shouldQuit());
}

test "StreamTerminal renders a widget tree" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 20, .height = 5 });
    defer terminal.deinit();

    // drop the startup bytes (alt-screen enter, mouse enable, etc.) so we
    // can examine only what render emits.
    const startup_len = output.written().len;

    var widget = Widget{ .text_box = try wgt.TextBox(Widget).init(allocator, "hello", .{ .border_style = .single, .wrap_kind = .none }) };
    defer widget.deinit();

    var last_size = layout.Size{ .width = 0, .height = 0 };
    var last_grid = try Grid.init(allocator, last_size);
    defer last_grid.deinit();

    _ = try terminal.render(&widget, &last_grid, &last_size);

    const rendered = output.written()[startup_len..];
    // we should see the rune 'h' from "hello" written somewhere in the output
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered, 'h') != null);
    // and a cursor-move CSI ("\x1B[r;cH") since render positions every rune
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1B[") != null);
}

test "StreamTerminal init and deinit emit alt-screen lifecycle" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });

    // after init we expect the alt-screen enter sequence and the hide-cursor sequence
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1B[?1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1B[?25l") != null);

    terminal.deinit();

    // after deinit we expect the leave-alt sequence and show-cursor
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1B[?1049l") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1B[?25h") != null);
}
