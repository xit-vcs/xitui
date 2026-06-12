const std = @import("std");
const builtin = @import("builtin");
const xitui = @import("xitui");
const term = xitui.terminal;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub fn main() !void {
    // init allocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = if (builtin.mode == .Debug) debug_allocator.allocator() else std.heap.smp_allocator;
    defer if (builtin.mode == .Debug) {
        _ = debug_allocator.deinit();
    };

    // init io
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    // init root widget
    var root = Widget{ .widget_list = try WidgetList.init(allocator) };
    defer root.deinit(allocator);

    // set initial focus for root widget
    try root.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 10, .height = 10 },
    }, root.getFocus());
    if (root.getFocus().child_id) |child_id| {
        try root.getFocus().setFocus(child_id);
    }

    // init term
    var terminal = try term.Terminal.init(io, allocator);
    defer terminal.deinit(io);

    var last_size = layout.Size{ .width = 0, .height = 0 };
    var last_grid = try Grid.init(allocator, last_size);
    defer last_grid.deinit();

    while (!term.quit.load(.monotonic)) {
        // render to tty
        const grid_changed = try terminal.render(&root, &last_grid, &last_size);

        // process any inputs
        //
        // if the grid didn't change, then first do a blocking
        // read, so the thread will sleep until further input.
        // after that, all remaining reads are non-blocking so
        // we can process the rest of the queued inputs.
        //
        // if the grid *did* change, then only do non-blocking
        // reads. we do not want to sleep the thread because
        // there may be an animation that requires more looping.
        var blocking = !grid_changed;
        while (try terminal.readKey(io, blocking)) |key| {
            blocking = false;
            switch (key) {
                .escape => return,
                .mouse => |mouse| {
                    if (mouse.action == .press and mouse.action.press == .left) {
                        const root_focus = root.getFocus();
                        var iter = root_focus.children.iterator();
                        while (iter.next()) |entry| {
                            const child = entry.value_ptr.*;
                            if (!child.focus.focusable) continue;
                            const r = child.rect;
                            if (mouse.x >= r.x and mouse.y >= r.y and
                                mouse.x < r.x + r.size.width and mouse.y < r.y + r.size.height)
                            {
                                try root_focus.setFocus(entry.key_ptr.*);
                                break;
                            }
                        }
                    } else {
                        try root.input(allocator, key, root.getFocus());
                    }
                },
                else => try root.input(allocator, key, root.getFocus()),
            }
        }

        // rebuild widget
        try root.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = last_size.width, .height = last_size.height },
        }, root.getFocus());

        // TODO: do variable sleep with target frame rate
        try std.Io.sleep(io, .fromMilliseconds(5), .real);
    }
}

const WidgetList = struct {
    scroll: wgt.Scroll(Widget),

    pub fn init(allocator: std.mem.Allocator) !WidgetList {
        var self = blk: {
            var inner_box = wgt.Box(Widget).init(.{ .border_style = null, .direction = .vert });
            errdefer inner_box.deinit(allocator);

            var scroll = try wgt.Scroll(Widget).init(allocator, .{ .box = inner_box }, .vert);
            errdefer scroll.deinit(allocator);

            break :blk WidgetList{
                .scroll = scroll,
            };
        };
        errdefer self.deinit(allocator);

        const inner_box = &self.scroll.child.box;

        {
            var text_input = wgt.TextInput(Widget).init(.{ .label = "username" });
            errdefer text_input.deinit(allocator);
            text_input.getFocus().focusable = true;
            try inner_box.children.put(allocator, text_input.getFocus().id, .{ .widget = .{ .text_input = text_input }, .rect = null, .min_size = null });
        }

        {
            var text_input = wgt.TextInput(Widget).init(.{ .label = "password", .password = true });
            errdefer text_input.deinit(allocator);
            text_input.getFocus().focusable = true;
            try inner_box.children.put(allocator, text_input.getFocus().id, .{ .widget = .{ .text_input = text_input }, .rect = null, .min_size = null });
        }

        {
            var text_box = try wgt.TextBox(Widget).init(allocator, "this is a TextBox", .{ .border_style = .single, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            try inner_box.children.put(allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
        }

        {
            var text_box = try wgt.TextBox(Widget).init(allocator, "this is a\nmulti-line TextBox", .{ .border_style = .single, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            try inner_box.children.put(allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
        }

        {
            var text_box = try wgt.TextBox(Widget).init(allocator, "another TextBox", .{ .border_style = .single, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            try inner_box.children.put(allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
        }

        {
            var text_box = try wgt.TextBox(Widget).init(allocator, "also a TextBox", .{ .border_style = .single, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            try inner_box.children.put(allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
        }

        {
            var text_box = try wgt.TextBox(Widget).init(allocator, "yet another TextBox", .{ .border_style = .single, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            try inner_box.children.put(allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
        }

        {
            var text_box = try wgt.TextBox(Widget).init(allocator, "one more TextBox", .{ .border_style = .single, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            text_box.getFocus().focusable = true;
            try inner_box.children.put(allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
        }

        if (inner_box.children.count() > 0) {
            self.scroll.getFocus().child_id = inner_box.children.keys()[0];
        }

        return self;
    }

    pub fn deinit(self: *WidgetList, allocator: std.mem.Allocator) void {
        self.scroll.deinit(allocator);
    }

    pub fn build(self: *WidgetList, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        try self.scroll.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *WidgetList, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
        if (self.getFocus().child_id) |child_id| {
            const children = &self.scroll.child.box.children;
            if (children.getIndex(child_id)) |current_index| {
                // forward text-editing keys to the focused TextInput so they
                // operate on the cursor rather than on the list itself.
                const focused = &children.values()[current_index].widget;
                if (focused.* == .text_input) {
                    switch (key) {
                        .codepoint, .arrow_left, .arrow_right, .home, .end, .delete, .backspace => {
                            try focused.input(allocator, key, root_focus);
                            return;
                        },
                        else => {},
                    }
                }

                var index = current_index;

                switch (key) {
                    .arrow_up => {
                        index -|= 1;
                    },
                    .arrow_down => {
                        if (index + 1 < children.count()) {
                            index += 1;
                        }
                    },
                    .home => {
                        index = 0;
                    },
                    .end => {
                        if (children.count() > 0) {
                            index = children.count() - 1;
                        }
                    },
                    .page_up => {
                        if (self.getGrid()) |grid| {
                            const half_count = (grid.size.height / 3) / 2;
                            index -|= half_count;
                        }
                    },
                    .page_down => {
                        if (self.getGrid()) |grid| {
                            if (children.count() > 0) {
                                const half_count = (grid.size.height / 3) / 2;
                                index = @min(index + half_count, children.count() - 1);
                            }
                        }
                    },
                    .mouse => |mouse| switch (mouse.action) {
                        .scroll => |dir| switch (dir) {
                            .up => index -|= 1,
                            .down => if (index + 1 < children.count()) {
                                index += 1;
                            },
                        },
                        else => {},
                    },
                    else => {},
                }

                if (index != current_index) {
                    try root_focus.setFocus(children.keys()[index]);
                    self.updateScroll(index);
                }
            }
        }
    }

    pub fn clearGrid(self: *WidgetList) void {
        self.scroll.clearGrid();
    }

    pub fn getGrid(self: WidgetList) ?Grid {
        return self.scroll.getGrid();
    }

    pub fn getFocus(self: *WidgetList) *Focus {
        return self.scroll.getFocus();
    }

    pub fn getSelectedIndex(self: WidgetList) ?usize {
        if (self.scroll.child.box.focus.child_id) |child_id| {
            const children = &self.scroll.child.box.children;
            return children.getIndex(child_id);
        } else {
            return null;
        }
    }

    fn updateScroll(self: *WidgetList, index: usize) void {
        const left_box = &self.scroll.child.box;
        if (left_box.children.values()[index].rect) |rect| {
            self.scroll.scrollToRect(rect);
        }
    }
};

pub const Widget = union(enum) {
    text: wgt.Text(Widget),
    box: wgt.Box(Widget),
    text_box: wgt.TextBox(Widget),
    text_input: wgt.TextInput(Widget),
    scroll: wgt.Scroll(Widget),
    widget_list: WidgetList,

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
