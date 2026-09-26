const std = @import("std");
const xitui = @import("xitui");
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const StreamTerminal = xitui.stream_terminal.StreamTerminal;

pub const Widget = union(enum) {
    text: wgt.Text,
    box: wgt.Box(Widget),
    text_box: wgt.TextBox,
    text_input: wgt.TextInput,
    scroll: wgt.Scroll(Widget),

    pub fn deinit(self: *Widget, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*case| case.deinit(allocator),
        }
    }

    pub fn build(self: *Widget, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.build(allocator, constraint, root_focus),
        }
    }

    pub fn input(self: *Widget, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.input(allocator, key, root_focus),
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

    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "Hello, world!", .{ .border_style = .single, .wrap_kind = .none }) };
    defer widget.deinit(allocator);

    try widget.build(allocator, .{
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

test "box grow child fills remaining minimum" {
    const allocator = std.testing.allocator;

    var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
    errdefer box.deinit(allocator);

    var left = try wgt.Text.init(allocator, "left");
    errdefer left.deinit(allocator);
    try box.children.put(allocator, left.getFocus().id, .{
        .widget = .{ .text = left },
        .rect = null,
        .min_size = .{ .width = 4, .height = null },
    });

    var spacer = try wgt.TextBox.init(allocator, "", .{ .border_style = null, .wrap_kind = .none });
    errdefer spacer.deinit(allocator);
    const spacer_id = spacer.getFocus().id;
    try box.children.put(allocator, spacer_id, .{
        .widget = .{ .text_box = spacer },
        .rect = null,
        .min_size = null,
        .flex = .grow,
    });

    var right = try wgt.Text.init(allocator, "right");
    errdefer right.deinit(allocator);
    try box.children.put(allocator, right.getFocus().id, .{
        .widget = .{ .text = right },
        .rect = null,
        .min_size = .{ .width = 5, .height = null },
    });

    var widget = Widget{ .box = box };
    defer widget.deinit(allocator);
    try widget.build(allocator, .{
        .min_size = .{ .width = 20, .height = null },
        .max_size = .{ .width = null, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("left           right", str);
    const spacer_child = widget.box.children.get(spacer_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 11), spacer_child.rect.?.size.width);
}

test "box shrink measurement does not change child constraints" {
    const allocator = std.testing.allocator;

    var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
    errdefer box.deinit(allocator);

    var shrinking = try wgt.TextBox.init(allocator, "abcdefghij", .{ .border_style = null, .wrap_kind = .none });
    errdefer shrinking.deinit(allocator);
    const shrinking_id = shrinking.getFocus().id;
    try box.children.put(allocator, shrinking_id, .{
        .widget = .{ .text_box = shrinking },
        .rect = null,
        .min_size = null,
        .flex = .shrink,
    });

    var fixed = try wgt.Text.init(allocator, "fixed");
    errdefer fixed.deinit(allocator);
    try box.children.put(allocator, fixed.getFocus().id, .{
        .widget = .{ .text = fixed },
        .rect = null,
        .min_size = .{ .width = 5, .height = null },
    });

    var widget = Widget{ .box = box };
    defer widget.deinit(allocator);
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 8, .height = null },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);
        try std.testing.expectEqualStrings("abcfixed", str);
    }
    const shrinking_child = widget.box.children.get(shrinking_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(shrinking_child.min_size == null);
    try std.testing.expect(shrinking_child.max_size == null);

    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = null, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("abcdefghijfixed", str);
}

test "text box with wrapping" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "Hello, world!\nGöödbye, world!", .{ .border_style = .single, .wrap_kind = .char }) };
    defer widget.deinit(allocator);

    try widget.build(allocator, .{
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

    try widget.build(allocator, .{
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

    try widget.build(allocator, .{
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

test "text box with wide characters" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "你好, world!", .{ .border_style = .single, .wrap_kind = .none }) };
    defer widget.deinit(allocator);

    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = null, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);

    // 你好 occupies four columns, so the border must span 12, not 10
    try std.testing.expectEqualStrings(
        \\┌────────────┐
        \\│你好, world!│
        \\└────────────┘
    , str);
}

test "text box char-wraps wide characters by columns" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "你好世界", .{ .border_style = .single, .wrap_kind = .char }) };
    defer widget.deinit(allocator);

    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 6, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);

    // four wide runes are eight columns: two per line at inner width 4
    try std.testing.expectEqualStrings(
        \\┌────┐
        \\│你好│
        \\│世界│
        \\└────┘
    , str);
}

test "text box wraps a wide character that does not fit the last column" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "ab你好", .{ .border_style = .single, .wrap_kind = .char }) };
    defer widget.deinit(allocator);

    // inner width 5: "ab" (2) + 你 (2) fit, but 好 would straddle the edge,
    // so it wraps early and leaves the fifth column blank
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 7, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);

    try std.testing.expectEqualStrings(
        \\┌────┐
        \\│ab你│
        \\│好  │
        \\└────┘
    , str);
}

test "text box word-wraps an unbroken wide run by columns" {
    const allocator = std.testing.allocator;

    // no spaces to break at, so the run is longer than a line and falls
    // back to char-wrapping — which must count columns, not codepoints
    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "你好世界你好", .{ .border_style = .single, .wrap_kind = .word }) };
    defer widget.deinit(allocator);

    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 6, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);

    try std.testing.expectEqualStrings(
        \\┌────┐
        \\│你好│
        \\│世界│
        \\│你好│
        \\└────┘
    , str);
}

test "horizontal scroll clips wide characters at the view edges" {
    const allocator = std.testing.allocator;

    const text = Widget{ .text = try wgt.Text.init(allocator, "你好世界") };
    var widget = Widget{ .scroll = try wgt.Scroll(Widget).init(allocator, text, .{ .direction = .horiz, .show_bar = false }) };
    defer widget.deinit(allocator);

    // viewport of 3 columns at offset 0: 你 fits, 好's lead is cut at the
    // right edge and renders as a blank column
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 3, .height = 1 },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);
        try std.testing.expectEqualStrings("你 ", str);
    }

    // offset 1: the left edge lands mid-你, blanking its trailing half
    widget.scroll.x = 1;
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 3, .height = 1 },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);
        try std.testing.expectEqualStrings(" 好", str);
    }
}

test "text input scrolls wide content by columns" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_input = try wgt.TextInput.init(allocator, .{ .border_style = null, .visible_width = 4 }) };
    defer widget.deinit(allocator);

    // 你(2) 好(2) a b c: the cursor lands past 'c', so the window slides
    // until the tail fits — 你 and 好 scroll out entirely
    try widget.text_input.setContent(allocator, "你好abc");
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = null, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("abc ", str);
}

test "vertical scroll bar" {
    const allocator = std.testing.allocator;

    const text_box = Widget{ .text_box = try wgt.TextBox.init(allocator, "aaaa\nbbbb\ncccc\ndddd\neeee\nffff", .{ .border_style = null, .wrap_kind = .none }) };
    var widget = Widget{ .scroll = try wgt.Scroll(Widget).init(allocator, text_box, .{ .direction = .vert, .show_bar = true }) };
    defer widget.deinit(allocator);

    // content is 6 rows tall, the viewport only 3, so the thumb covers half
    // the track. the bar takes the far right column, narrowing content to 4.
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 5, .height = 3 },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\aaaa█
            \\bbbb█
            \\cccc░
        , str);
    }

    // scroll to the bottom; the thumb slides down to the end of the track.
    widget.scroll.scrollToRect(.{ .x = 0, .y = 5, .size = .{ .width = 1, .height = 1 } });
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 5, .height = 3 },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\dddd░
            \\eeee█
            \\ffff█
        , str);
    }
}

test "scroll bar hidden when content fits" {
    const allocator = std.testing.allocator;

    const text_box = Widget{ .text_box = try wgt.TextBox.init(allocator, "aaaa\nbbbb\ncccc", .{ .border_style = null, .wrap_kind = .none }) };
    var widget = Widget{ .scroll = try wgt.Scroll(Widget).init(allocator, text_box, .{ .direction = .vert, .show_bar = true }) };
    defer widget.deinit(allocator);

    // the viewport is taller than the content, so nothing scrolls: no bar is
    // drawn and no column is reserved (content keeps its full width).
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 5, .height = 5 },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\aaaa
            \\bbbb
            \\cccc
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

test "StreamTerminal parses ctrl+letter" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    // ctrl+a and ctrl+r are C0 control chars
    try terminal.writeBytes("\x01\x12");
    try std.testing.expectEqual(@as(?inp.Key, .{ .ctrl = 'a' }), terminal.popKey());
    try std.testing.expectEqual(@as(?inp.Key, .{ .ctrl = 'r' }), terminal.popKey());

    // ctrl+h, ctrl+i, and ctrl+m still arrive as their named keys
    try terminal.writeBytes("\x08\x09\x0D");
    try std.testing.expectEqual(@as(?inp.Key, .backspace), terminal.popKey());
    try std.testing.expectEqual(@as(?inp.Key, .tab), terminal.popKey());
    try std.testing.expectEqual(@as(?inp.Key, .enter), terminal.popKey());
}

test "StreamTerminal parses alt+letter" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    try terminal.writeBytes("\x1Bx");
    try std.testing.expectEqual(@as(?inp.Key, .{ .alt = 'x' }), terminal.popKey());

    // a lone ESC is held back — the next frame may carry the rest of a
    // sequence — until the driver flushes it
    try terminal.writeBytes("\x1B");
    try std.testing.expectEqual(@as(?inp.Key, null), terminal.popKey());
    try terminal.flushEscape();
    try std.testing.expectEqual(@as(?inp.Key, .escape), terminal.popKey());
}

test "StreamTerminal keeps keys in arrival order across feeds" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    try terminal.writeBytes("ab");
    try terminal.writeBytes("cd");

    var got: [4]u8 = undefined;
    for (&got) |*g| g.* = @intCast(terminal.popKey().?.codepoint);
    try std.testing.expectEqualStrings("abcd", &got);
}

test "StreamTerminal resolves utf-8 split across feeds" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    try terminal.writeBytes("a\xe2");
    try terminal.writeBytes("\x82");
    try terminal.writeBytes("\xacb");

    try std.testing.expectEqual(@as(u21, 'a'), terminal.popKey().?.codepoint);
    try std.testing.expectEqual(@as(u21, '€'), terminal.popKey().?.codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), terminal.popKey().?.codepoint);
}

test "StreamTerminal resolves a sequence split across feeds" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    try terminal.writeBytes("\x1B");
    try terminal.writeBytes("[A");
    try std.testing.expectEqual(@as(?inp.Key, .arrow_up), terminal.popKey());
    try std.testing.expectEqual(@as(?inp.Key, null), terminal.popKey());

    // split mid-parameter too
    try terminal.writeBytes("\x1B[1");
    try terminal.writeBytes("5~");
    try std.testing.expectEqual(@as(?inp.Key, .{ .f = 5 }), terminal.popKey());
}

test "StreamTerminal survives an over-long escape sequence" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    // a device attributes reply longer than the parser's scratch buffer: it
    // reports as one unknown key, tail and all, and input keeps working
    try terminal.writeBytes("\x1B[?" ++ ("1;" ** 100) ++ "2c");
    try std.testing.expectEqual(@as(?inp.Key, .unknown), terminal.popKey());
    try std.testing.expectEqual(@as(?inp.Key, null), terminal.popKey());

    try terminal.writeBytes("\x1B[Aq");
    try std.testing.expectEqual(@as(?inp.Key, .arrow_up), terminal.popKey());
    try std.testing.expectEqual(@as(u21, 'q'), terminal.popKey().?.codepoint);
}

test "StreamTerminal reports repeated escape presses" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    // ESC followed by a control byte can't be an alt combo, so the first ESC
    // resolves on its own and the second opens the next sequence
    try terminal.writeBytes("\x1B\x1B[A");
    try std.testing.expectEqual(@as(?inp.Key, .escape), terminal.popKey());
    try std.testing.expectEqual(@as(?inp.Key, .arrow_up), terminal.popKey());
}

test "StreamTerminal parses function keys and insert" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    // F1 — SS3 style
    try terminal.writeBytes("\x1BOP");
    try std.testing.expectEqual(@as(?inp.Key, .{ .f = 1 }), terminal.popKey());

    // F2 — old xterm/rxvt CSI style
    try terminal.writeBytes("\x1B[12~");
    try std.testing.expectEqual(@as(?inp.Key, .{ .f = 2 }), terminal.popKey());

    // F5 and F12 — CSI style, with the historical gaps in the code sequence
    try terminal.writeBytes("\x1B[15~");
    try std.testing.expectEqual(@as(?inp.Key, .{ .f = 5 }), terminal.popKey());
    try terminal.writeBytes("\x1B[24~");
    try std.testing.expectEqual(@as(?inp.Key, .{ .f = 12 }), terminal.popKey());

    try terminal.writeBytes("\x1B[2~");
    try std.testing.expectEqual(@as(?inp.Key, .insert), terminal.popKey());
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

    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "hello", .{ .border_style = .single, .wrap_kind = .none }) };
    defer widget.deinit(allocator);

    _ = try terminal.render(&widget);

    const rendered = output.written()[startup_len..];
    // we should see the rune 'h' from "hello" written somewhere in the output
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered, 'h') != null);
    // and a cursor move for the first run
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1B[") != null);

    const unchanged_start = output.written().len;
    try std.testing.expect(!try terminal.render(&widget));
    try std.testing.expectEqualStrings(
        "",
        output.written()[unchanged_start..],
    );

    try widget.text_box.setContent(allocator, "jello");
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 20, .height = 5 },
    }, widget.getFocus());

    const changed_start = output.written().len;
    try std.testing.expect(try terminal.render(&widget));
    try std.testing.expectEqualStrings(
        "\x1B[?2026h\x1B[2;2Hj\x1B[?2026l",
        output.written()[changed_start..],
    );

    const grid = &widget.text_box.grid.?;
    (try grid.cell(1, 1)).style.inverted = true;

    const styled_start = output.written().len;
    try std.testing.expect(try terminal.render(&widget));
    try std.testing.expectEqualStrings(
        "\x1B[?2026h\x1B[2;2H\x1B[7mj\x1B[0m\x1B[?2026l",
        output.written()[styled_start..],
    );

    // attributes then colors, after the per-frame reset state
    const cases = [_]struct { style: Grid.Style, sgr: []const u8 }{
        .{ .style = .{ .bold = true, .fg = .{ .ansi = .red } }, .sgr = "\x1B[1m\x1B[31m" },
        .{ .style = .{ .fg = .{ .ansi = .bright_red }, .bg = .{ .ansi = .bright_blue } }, .sgr = "\x1B[91m\x1B[104m" },
        .{ .style = .{ .bg = .{ .indexed = 17 } }, .sgr = "\x1B[48;5;17m" },
        .{ .style = .{ .bg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .underline = true }, .sgr = "\x1B[4m\x1B[48;2;1;2;3m" },
    };
    for (cases) |case| {
        (try grid.cell(1, 1)).style = case.style;
        const start = output.written().len;
        try std.testing.expect(try terminal.render(&widget));
        const expected = try std.mem.concat(allocator, u8, &.{ "\x1B[?2026h\x1B[2;2H", case.sgr, "j\x1B[0m\x1B[?2026l" });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, output.written()[start..]);
    }
}

test "StreamTerminal paints the terminal background" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 20, .height = 5 });
    defer terminal.deinit();
    terminal.setBackground(.{ .indexed = 236 });

    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "hello", .{ .border_style = .single, .wrap_kind = .none }) };
    defer widget.deinit(allocator);

    const first_start = output.written().len;
    _ = try terminal.render(&widget);
    const first = output.written()[first_start..];
    // the bg is set before the clear so the cleared spaces carry it
    const bg_index = std.mem.indexOf(u8, first, "\x1B[48;5;236m").?;
    const clear_index = std.mem.indexOf(u8, first, "\x1B[1;1H").?;
    try std.testing.expect(bg_index < clear_index);
    // unstyled cells already match the seeded style, so no further sgr
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, first, "\x1B[48;5;236m"));
    try std.testing.expect(std.mem.endsWith(u8, first, "\x1B[0m\x1B[?2026l"));

    // an unchanged background and frame stay silent
    const unchanged_start = output.written().len;
    terminal.setBackground(.{ .indexed = 236 });
    try std.testing.expect(!try terminal.render(&widget));
    try std.testing.expectEqualStrings("", output.written()[unchanged_start..]);

    // a new background forces a full refresh
    terminal.setBackground(.{ .rgb = .{ .r = 9, .g = 8, .b = 7 } });
    const changed_start = output.written().len;
    try std.testing.expect(try terminal.render(&widget));
    const changed = output.written()[changed_start..];
    try std.testing.expect(std.mem.startsWith(u8, changed, "\x1B[?2026h\x1B[48;2;9;8;7m\x1B[1;1H"));
    try std.testing.expect(std.mem.indexOf(u8, changed, "hello") != null);

    // clearing it refreshes without any bg
    terminal.setBackground(null);
    const cleared_start = output.written().len;
    try std.testing.expect(try terminal.render(&widget));
    const cleared = output.written()[cleared_start..];
    try std.testing.expect(std.mem.startsWith(u8, cleared, "\x1B[?2026h\x1B[1;1H"));
    try std.testing.expect(std.mem.indexOf(u8, cleared, "48;") == null);
}

test "TextBox spans layer over the option style" {
    const allocator = std.testing.allocator;
    const blue: Grid.Color = .{ .ansi = .blue };
    const red: Grid.Color = .{ .ansi = .red };

    var text_box = try wgt.TextBox.initSpans(allocator, &.{
        .{ .text = "ab", .style = .{ .fg = red } },
        .{ .text = "c", .style = .{ .bold = true } },
    }, .{ .border_style = .single, .wrap_kind = .none, .style = .{ .bg = blue } });
    defer text_box.deinit(allocator);

    const constraint: layout.Constraint = .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 20, .height = 5 },
    };
    try text_box.build(allocator, constraint, text_box.getFocus());
    {
        const grid = text_box.getGrid().?;
        const str = try grid.toString(allocator);
        defer allocator.free(str);
        try std.testing.expectEqualStrings("┌───┐\n│abc│\n└───┘", str);

        const a = try grid.cell(1, 1);
        try std.testing.expect(a.style.eql(.{ .fg = red, .bg = blue }));
        const b = try grid.cell(2, 1);
        try std.testing.expect(b.style.eql(.{ .fg = red, .bg = blue }));
        const c = try grid.cell(3, 1);
        try std.testing.expect(c.style.eql(.{ .bold = true, .bg = blue }));
        // the border picks up the widget-wide style
        try std.testing.expect((try grid.cell(0, 0)).style.eql(.{ .bg = blue }));
    }

    // inversion covers the border and the text
    text_box.options.invert = true;
    try text_box.build(allocator, constraint, text_box.getFocus());
    {
        const grid = text_box.getGrid().?;
        try std.testing.expect((try grid.cell(0, 0)).style.eql(.{ .bg = blue, .inverted = true }));
        try std.testing.expect((try grid.cell(1, 1)).style.eql(.{ .fg = red, .bg = blue, .inverted = true }));
        for (grid.cells) |cell| try std.testing.expect(cell.style.inverted);
    }

    // plain content replaces the runs with a single unstyled one
    text_box.options.invert = false;
    try text_box.setContent(allocator, "xyz");
    try std.testing.expectEqual(@as(usize, 1), text_box.runs.items.len);
    try text_box.build(allocator, constraint, text_box.getFocus());
    {
        const grid = text_box.getGrid().?;
        for (1..4) |x| try std.testing.expect((try grid.cell(x, 1)).style.eql(.{ .bg = blue }));
    }
}

test "inverted TextInput flips its cursor back" {
    const allocator = std.testing.allocator;
    var widget = Widget{ .text_input = try wgt.TextInput.init(allocator, .{ .invert = true, .visible_width = 5 }) };
    defer widget.deinit(allocator);
    // a root widget is its own focused leaf
    widget.getFocus().grandchild_id = widget.getFocus().id;
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 20, .height = 5 },
    }, widget.getFocus());
    const grid = widget.getGrid().?;
    // the border is inverted, the cursor cell is not
    try std.testing.expect((try grid.cell(0, 0)).style.inverted);
    try std.testing.expect(!(try grid.cell(1, 1)).style.inverted);
    try std.testing.expect((try grid.cell(2, 1)).style.inverted);
}

test "Text applies its style to every cell" {
    const allocator = std.testing.allocator;
    var text = try wgt.Text.init(allocator, "a中");
    defer text.deinit(allocator);
    text.style = .{ .dim = true, .fg = .{ .indexed = 3 } };
    try text.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 20, .height = 1 },
    }, text.getFocus());
    const grid = text.getGrid().?;
    try std.testing.expectEqual(@as(usize, 3), grid.size.width);
    // the wide rune's continuation shares the style too
    try std.testing.expect(grid.cells[2].continuation);
    for (grid.cells) |cell| try std.testing.expect(cell.style.eql(text.style));
}

test "cursor control sequence stays whole at a writer boundary" {
    const ChunkWriter = struct {
        output: std.Io.Writer.Allocating,
        interface: std.Io.Writer,

        fn init(allocator: std.mem.Allocator, buffer: []u8) @This() {
            return .{
                .output = .init(allocator),
                .interface = .{
                    .vtable = &.{ .drain = drain },
                    .buffer = buffer,
                },
            };
        }

        fn deinit(self: *@This()) void {
            self.output.deinit();
        }

        fn drain(writer: *std.Io.Writer, _: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            if (splat != 1) return error.WriteFailed;
            const self: *@This() = @alignCast(@fieldParentPtr("interface", writer));
            self.output.writer.writeAll(writer.buffered()) catch return error.WriteFailed;
            self.output.writer.writeByte('|') catch return error.WriteFailed;
            return writer.consumeAll();
        }
    };

    var buffer: [8]u8 = undefined;
    var writer = ChunkWriter.init(std.testing.allocator, &buffer);
    defer writer.deinit();

    try writer.interface.writeAll("xxxxxx");
    try xitui.terminal.moveCursor(&writer.interface, 101, 0);
    try writer.interface.flush();

    try std.testing.expectEqualStrings(
        "xxxxxx|\x1B[1;102H|",
        writer.output.written(),
    );
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
