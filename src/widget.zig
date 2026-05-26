const std = @import("std");
const Grid = @import("./grid.zig").Grid;
const Focus = @import("./focus.zig").Focus;
const layout = @import("./layout.zig");
const inp = @import("./input.zig");

pub fn Text(comptime Widget: type) type {
    return struct {
        allocator: std.mem.Allocator,
        focus: Focus,
        grid: ?Grid,
        content: []const u8,

        pub fn init(allocator: std.mem.Allocator, content: []const u8) Text(Widget) {
            return .{
                .allocator = allocator,
                .focus = Focus.init(allocator, .text),
                .grid = null,
                .content = content,
            };
        }

        pub fn deinit(self: *Text(Widget)) void {
            self.focus.deinit();
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }

        pub fn build(self: *Text(Widget), constraint: layout.Constraint, root_focus: *Focus) !void {
            _ = root_focus;
            self.clearGrid();
            const width = try std.unicode.utf8CountCodepoints(self.content);
            var grid = try Grid.init(self.allocator, .{ .width = @max(1, @min(width, constraint.max_size.width orelse width)), .height = 1 });
            errdefer grid.deinit();
            var utf8 = (try std.unicode.Utf8View.init(self.content)).iterator();
            var i: u32 = 0;
            while (utf8.nextCodepointSlice()) |char| {
                if (i == grid.size.width) {
                    break;
                }
                grid.cells.items[try grid.cells.at(.{ 0, i })].rune = char;
                i += 1;
            }
            self.grid = grid;
        }

        pub fn input(self: *Text(Widget), key: inp.Key, root_focus: *Focus) !void {
            _ = self;
            _ = key;
            _ = root_focus;
        }

        pub fn clearGrid(self: *Text(Widget)) void {
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }

        pub fn getGrid(self: Text(Widget)) ?Grid {
            return self.grid;
        }

        pub fn getFocus(self: *Text(Widget)) *Focus {
            return &self.focus;
        }
    };
}

pub const BorderStyle = enum {
    hidden,
    single,
    double,
    single_dashed,
    double_dashed,
};

pub fn Box(comptime Widget: type) type {
    return struct {
        focus: Focus,
        grid: ?Grid,
        allocator: std.mem.Allocator,
        children: std.AutoArrayHashMapUnmanaged(usize, Child),
        options: Options,

        pub const Child = struct {
            widget: Widget,
            rect: ?layout.IRect,
            min_size: ?layout.MaybeSize,
        };

        pub const Direction = enum {
            vert,
            horiz,
        };

        pub const Options = struct {
            border_style: ?BorderStyle,
            rounded_corners: bool = false,
            direction: Direction,
        };

        pub fn init(allocator: std.mem.Allocator, options: Options) !Box(Widget) {
            return .{
                .focus = Focus.init(allocator, .container),
                .grid = null,
                .allocator = allocator,
                .children = .empty,
                .options = options,
            };
        }

        pub fn deinit(self: *Box(Widget)) void {
            self.focus.deinit();
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
            for (self.children.values()) |*child| {
                child.widget.deinit();
            }
            self.children.deinit(self.allocator);
        }

        pub fn build(self: *Box(Widget), constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();

            const border_size: usize = if (self.options.border_style) |_| 1 else 0;
            if (constraint.max_size.width) |max_width| {
                if (max_width <= border_size * 2) return;
            }
            if (constraint.max_size.height) |max_height| {
                if (max_height <= border_size * 2) return;
            }

            var sorted_children: std.AutoArrayHashMapUnmanaged(usize, void) = .empty;
            defer sorted_children.deinit(self.allocator);
            var should_sort = false;
            for (self.children.values(), 0..) |child, i| {
                try sorted_children.put(self.allocator, i, {});
                if (child.min_size != null) {
                    should_sort = true;
                }
            }
            if (should_sort) {
                const SortCtx = struct {
                    selected_index: usize,

                    pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                        const ia: isize = @intCast(a_index);
                        const ib: isize = @intCast(b_index);
                        const a_priority = if (ia <= ctx.selected_index) ia else -ia;
                        const b_priority = if (ib <= ctx.selected_index) ib else -ib;
                        return a_priority > b_priority;
                    }
                };
                if (self.getFocus().child_id) |child_id| {
                    if (self.children.getIndex(child_id)) |index| {
                        sorted_children.sort(SortCtx{ .selected_index = index });
                    }
                }
            }

            var width: usize = 0;
            var height: usize = 0;
            var remaining_width_maybe = if (constraint.max_size.width) |max_width| max_width - (border_size * 2) else null;
            var remaining_height_maybe = if (constraint.max_size.height) |max_height| max_height - (border_size * 2) else null;

            for (sorted_children.keys(), 0..) |child_index, sorted_child_index| {
                var child = &self.children.values()[child_index];
                child.widget.clearGrid();

                // skip any children after the first if their min size is too large
                if (sorted_child_index > 0) {
                    if (remaining_width_maybe) |remaining_width| {
                        if (remaining_width <= 0) continue;
                        if (child.min_size) |min_size| {
                            if (min_size.width) |min_width| {
                                if (remaining_width < min_width) continue;
                            }
                        }
                    }
                    if (remaining_height_maybe) |remaining_height| {
                        if (remaining_height <= 0) continue;
                        if (child.min_size) |min_size| {
                            if (min_size.height) |min_height| {
                                if (remaining_height < min_height) continue;
                            }
                        }
                    }
                }

                // make room for the next children if they have min sizes
                var expected_remaining_width_maybe = remaining_width_maybe;
                var expected_remaining_height_maybe = remaining_height_maybe;
                var child_min_size: layout.MaybeSize = .{ .width = null, .height = null };
                if (child.min_size) |min_size| {
                    child_min_size = min_size;
                    if (expected_remaining_width_maybe) |*expected_remaining_width| {
                        if (min_size.width) |min_width| {
                            for (sorted_child_index + 1..sorted_children.count()) |next_sorted_child_index| {
                                const next_child_index = sorted_children.keys()[next_sorted_child_index];
                                const next_child = &self.children.values()[next_child_index];
                                if (next_child.min_size) |next_min_size| {
                                    if (next_min_size.width) |next_min_width| {
                                        if (expected_remaining_width.* >= min_width + next_min_width) {
                                            expected_remaining_width.* -= next_min_width;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if (expected_remaining_height_maybe) |*expected_remaining_height| {
                        if (min_size.height) |min_height| {
                            for (sorted_child_index + 1..sorted_children.count()) |next_sorted_child_index| {
                                const next_child_index = sorted_children.keys()[next_sorted_child_index];
                                const next_child = &self.children.values()[next_child_index];
                                if (next_child.min_size) |next_min_size| {
                                    if (next_min_size.height) |next_min_height| {
                                        if (expected_remaining_height.* >= min_height + next_min_height) {
                                            expected_remaining_height.* -= next_min_height;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                try child.widget.build(.{
                    .min_size = child_min_size,
                    .max_size = .{ .width = expected_remaining_width_maybe, .height = expected_remaining_height_maybe },
                }, root_focus);

                if (child.widget.getGrid()) |child_grid| {
                    switch (self.options.direction) {
                        .vert => {
                            if (remaining_height_maybe) |*remaining_height| remaining_height.* -|= child_grid.size.height;
                            width = @max(width, child_grid.size.width);
                            height += child_grid.size.height;
                        },
                        .horiz => {
                            if (remaining_width_maybe) |*remaining_width| remaining_width.* -|= child_grid.size.width;
                            width += child_grid.size.width;
                            height = @max(height, child_grid.size.height);
                        },
                    }
                }
            }

            width += border_size * 2;
            width = @max(width, constraint.min_size.width orelse width);
            height += border_size * 2;
            height = @max(height, constraint.min_size.height orelse height);

            var grid = try Grid.init(self.allocator, .{ .width = width, .height = height });
            errdefer grid.deinit();

            self.getFocus().clear();

            switch (self.options.direction) {
                .vert => {
                    var line: usize = 0;
                    for (self.children.values()) |*child| {
                        if (child.widget.getGrid()) |child_grid| {
                            child.rect = .{ .x = 0, .y = @as(isize, @intCast(line + border_size)), .size = child_grid.size };
                            try grid.drawGrid(child_grid, border_size, line + border_size);
                            try self.getFocus().addChild(child.widget.getFocus(), child_grid.size, border_size, line + border_size);
                            line += child_grid.size.height;
                        } else {
                            try self.getFocus().addChild(child.widget.getFocus(), .{ .width = 0, .height = 0 }, 0, 0);
                        }
                    }
                },
                .horiz => {
                    var col: usize = 0;
                    for (self.children.values()) |*child| {
                        if (child.widget.getGrid()) |child_grid| {
                            child.rect = .{ .x = @as(isize, @intCast(col + border_size)), .y = 0, .size = child_grid.size };
                            try grid.drawGrid(child_grid, col + border_size, border_size);
                            try self.getFocus().addChild(child.widget.getFocus(), child_grid.size, col + border_size, border_size);
                            col += child_grid.size.width;
                        } else {
                            try self.getFocus().addChild(child.widget.getFocus(), .{ .width = 0, .height = 0 }, 0, 0);
                        }
                    }
                },
            }

            // border style
            if (self.options.border_style) |border_style| {
                const horiz_line = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => "─",
                    .double, .double_dashed => "═",
                };
                const vert_line = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => "│",
                    .double, .double_dashed => "║",
                };
                const top_left_corner = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => if (self.options.rounded_corners) "╭" else "┌",
                    .double, .double_dashed => if (self.options.rounded_corners) "╭" else "╔",
                };
                const top_right_corner = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => if (self.options.rounded_corners) "╮" else "┐",
                    .double, .double_dashed => if (self.options.rounded_corners) "╮" else "╗",
                };
                const bottom_left_corner = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => if (self.options.rounded_corners) "╰" else "└",
                    .double, .double_dashed => if (self.options.rounded_corners) "╰" else "╚",
                };
                const bottom_right_corner = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => if (self.options.rounded_corners) "╯" else "┘",
                    .double, .double_dashed => if (self.options.rounded_corners) "╯" else "╝",
                };
                // top and bottom border
                for (1..grid.size.width - 1) |x| {
                    if ((border_style == .single_dashed or border_style == .double_dashed) and x % 2 == 1) continue;
                    grid.cells.items[try grid.cells.at(.{ 0, x })].rune = horiz_line;
                    grid.cells.items[try grid.cells.at(.{ grid.size.height - 1, x })].rune = horiz_line;
                }
                // left and right border
                for (1..grid.size.height - 1) |y| {
                    if ((border_style == .single_dashed or border_style == .double_dashed) and y % 2 == 1) continue;
                    grid.cells.items[try grid.cells.at(.{ y, 0 })].rune = vert_line;
                    grid.cells.items[try grid.cells.at(.{ y, grid.size.width - 1 })].rune = vert_line;
                }
                // corners
                grid.cells.items[try grid.cells.at(.{ 0, 0 })].rune = top_left_corner;
                grid.cells.items[try grid.cells.at(.{ 0, grid.size.width - 1 })].rune = top_right_corner;
                grid.cells.items[try grid.cells.at(.{ grid.size.height - 1, 0 })].rune = bottom_left_corner;
                grid.cells.items[try grid.cells.at(.{ grid.size.height - 1, grid.size.width - 1 })].rune = bottom_right_corner;
            }

            // set grid
            self.grid = grid;
        }

        pub fn input(self: *Box(Widget), key: inp.Key, root_focus: *Focus) !void {
            for (self.children.values()) |*child| {
                try child.widget.input(key, root_focus);
            }
        }

        pub fn clearGrid(self: *Box(Widget)) void {
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }

        pub fn getGrid(self: Box(Widget)) ?Grid {
            return self.grid;
        }

        pub fn getFocus(self: *Box(Widget)) *Focus {
            return &self.focus;
        }
    };
}

pub const WrapKind = enum {
    none,
    char,
};

pub fn TextBox(comptime Widget: type) type {
    return struct {
        allocator: std.mem.Allocator,
        box: Box(Widget),
        options: Options,
        last_wrap_width: ?usize,
        content: []const u8,
        lines: std.ArrayList([]const u8),

        pub const Options = struct {
            border_style: ?BorderStyle,
            rounded_corners: bool = true,
            wrap_kind: WrapKind,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            content: []const u8,
            options: Options,
        ) !TextBox(Widget) {
            var lines: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (lines.items) |line| {
                    allocator.free(line);
                }
                lines.deinit(allocator);
            }

            {
                var line: std.ArrayList(u8) = .empty;
                errdefer line.deinit(allocator);

                var utf8 = (try std.unicode.Utf8View.init(content)).iterator();
                while (utf8.nextCodepointSlice()) |char| {
                    if (std.mem.eql(u8, char, "\n")) {
                        try lines.append(allocator, try line.toOwnedSlice(allocator));
                    } else {
                        try line.appendSlice(allocator, char);
                    }
                }
                try lines.append(allocator, try line.toOwnedSlice(allocator));
            }

            var box = try Box(Widget).init(allocator, .{ .border_style = options.border_style, .rounded_corners = options.rounded_corners, .direction = .vert });
            errdefer box.deinit();
            box.getFocus().kind = .text_box;
            for (lines.items) |line| {
                var text = Text(Widget).init(allocator, line);
                errdefer text.deinit();
                try box.children.put(allocator, text.getFocus().id, .{ .widget = .{ .text = text }, .rect = null, .min_size = null });
            }

            return .{
                .allocator = allocator,
                .box = box,
                .options = options,
                .last_wrap_width = null,
                .content = content,
                .lines = lines,
            };
        }

        pub fn deinit(self: *TextBox(Widget)) void {
            self.box.deinit();
            for (self.lines.items) |line| {
                self.allocator.free(line);
            }
            self.lines.deinit(self.allocator);
        }

        pub fn build(self: *TextBox(Widget), constraint: layout.Constraint, root_focus: *Focus) !void {
            if (.char == self.options.wrap_kind) {
                if (constraint.max_size.width) |max_width| {
                    const should_rewrap = if (self.last_wrap_width) |last_wrap_width| last_wrap_width != max_width else true;
                    self.last_wrap_width = max_width;

                    if (should_rewrap) {
                        const border_size: usize = if (self.options.border_style) |_| 1 else 0;

                        {
                            for (self.lines.items) |line| {
                                self.allocator.free(line);
                            }
                            self.lines.clearAndFree(self.allocator);

                            var line: std.ArrayList(u8) = .empty;
                            errdefer line.deinit(self.allocator);

                            var utf8 = (try std.unicode.Utf8View.init(self.content)).iterator();
                            while (utf8.nextCodepointSlice()) |char| {
                                if (std.mem.eql(u8, char, "\n")) {
                                    try self.lines.append(self.allocator, try line.toOwnedSlice(self.allocator));
                                } else {
                                    try line.appendSlice(self.allocator, char);
                                }

                                if (std.mem.eql(u8, utf8.peek(1), "")) {
                                    try self.lines.append(self.allocator, try line.toOwnedSlice(self.allocator));
                                } else if (try std.unicode.utf8CountCodepoints(line.items) + (border_size * 2) == max_width) {
                                    try self.lines.append(self.allocator, try line.toOwnedSlice(self.allocator));
                                }
                            }
                        }

                        const box = try Box(Widget).init(self.allocator, .{ .border_style = self.options.border_style, .rounded_corners = self.options.rounded_corners, .direction = .vert });
                        self.box.deinit();
                        self.box = box;
                        for (self.lines.items) |line| {
                            var text = Text(Widget).init(self.allocator, line);
                            errdefer text.deinit();
                            try self.box.children.put(self.allocator, text.getFocus().id, .{ .widget = .{ .text = text }, .rect = null, .min_size = null });
                        }
                    }
                }
            }

            self.clearGrid();
            self.box.options.border_style = self.options.border_style;
            self.box.options.rounded_corners = self.options.rounded_corners;
            try self.box.build(constraint, root_focus);
        }

        pub fn input(self: *TextBox(Widget), key: inp.Key, root_focus: *Focus) !void {
            try self.box.input(key, root_focus);
        }

        pub fn clearGrid(self: *TextBox(Widget)) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: TextBox(Widget)) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *TextBox(Widget)) *Focus {
            return self.box.getFocus();
        }
    };
}

pub fn TextInput(comptime Widget: type) type {
    return struct {
        allocator: std.mem.Allocator,
        focus: Focus,
        grid: ?Grid,
        content: std.ArrayList([]const u8),
        cursor: usize,
        scroll_offset: usize,
        options: Options,

        pub const Options = struct {
            border_style: ?BorderStyle = .single_dashed,
            rounded_corners: bool = true,
            // visible width in codepoints, excluding the border
            visible_width: usize = 20,
            // when true, every character is rendered as a bullet so the
            // actual content isn't visible on screen
            password: bool = false,
            // optional label rendered over the top border (e.g. "username").
            // when empty, the border is drawn unchanged.
            label: []const u8 = "",
            // optional form-field name; the web renderer emits it as the
            // HTML `name` attribute so the value is submitted with that key.
            name: []const u8 = "",
        };

        pub fn init(allocator: std.mem.Allocator, options: Options) TextInput(Widget) {
            return .{
                .allocator = allocator,
                .focus = Focus.init(allocator, if (options.password) .text_input_password else .text_input),
                .grid = null,
                .content = .empty,
                .cursor = 0,
                .scroll_offset = 0,
                .options = options,
            };
        }

        pub fn deinit(self: *TextInput(Widget)) void {
            self.focus.deinit();
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
            for (self.content.items) |cp| self.allocator.free(cp);
            self.content.deinit(self.allocator);
        }

        // replaces all typed content with the codepoints in `bytes`, dropping
        // existing allocations. cursor lands at the end so subsequent edits
        // (or rendering) treat the supplied text as the new state.
        pub fn setContent(self: *TextInput(Widget), bytes: []const u8) !void {
            for (self.content.items) |cp| self.allocator.free(cp);
            self.content.clearAndFree(self.allocator);

            var utf8 = (try std.unicode.Utf8View.init(bytes)).iterator();
            while (utf8.nextCodepointSlice()) |cp_slice| {
                const owned = try self.allocator.dupe(u8, cp_slice);
                errdefer self.allocator.free(owned);
                try self.content.append(self.allocator, owned);
            }

            self.cursor = self.content.items.len;
            self.scroll_offset = 0;
        }

        pub fn clear(self: *TextInput(Widget)) void {
            for (self.content.items) |cp| self.allocator.free(cp);
            self.content.clearAndFree(self.allocator);
            self.cursor = 0;
            self.scroll_offset = 0;
        }

        pub fn build(self: *TextInput(Widget), constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();

            const effective_border: ?BorderStyle = if (self.options.border_style) |base| switch (base) {
                .hidden => .hidden,
                else => if (root_focus.grandchild_id == self.focus.id) .double_dashed else .single_dashed,
            } else null;

            const border_size: usize = if (effective_border) |_| 1 else 0;
            const height: usize = 1 + border_size * 2;

            // width is fixed at the option's visible_width; longer content
            // scrolls horizontally inside it.
            const desired_width = self.options.visible_width + border_size * 2;
            const width: usize = if (constraint.max_size.width) |max_width|
                @min(desired_width, max_width)
            else
                desired_width;

            if (width <= border_size * 2) return;

            const inner_width = width - border_size * 2;

            // keep cursor inside the visible window
            if (self.cursor < self.scroll_offset) {
                self.scroll_offset = self.cursor;
            } else if (self.cursor >= self.scroll_offset + inner_width) {
                self.scroll_offset = self.cursor + 1 - inner_width;
            }

            var grid = try Grid.init(self.allocator, .{ .width = width, .height = height });
            errdefer grid.deinit();

            // text + cursor
            for (0..inner_width) |i| {
                const content_index = self.scroll_offset + i;
                const cell_x = i + border_size;
                const cell_y = border_size;
                const cell_idx = try grid.cells.at(.{ cell_y, cell_x });
                if (content_index < self.content.items.len) {
                    grid.cells.items[cell_idx].rune = if (self.options.password) "•" else self.content.items[content_index];
                } else if (content_index == self.content.items.len and self.cursor == content_index) {
                    // cursor sits past the last char — paint a space underneath
                    grid.cells.items[cell_idx].rune = " ";
                }
                if (content_index == self.cursor) {
                    grid.cells.items[cell_idx].style.inverted = true;
                    if (grid.cells.items[cell_idx].rune == null) {
                        grid.cells.items[cell_idx].rune = " ";
                    }
                }
            }

            // border
            if (effective_border) |border_style| {
                const horiz_line = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => "─",
                    .double, .double_dashed => "═",
                };
                const vert_line = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => "│",
                    .double, .double_dashed => "║",
                };
                const top_left = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => if (self.options.rounded_corners) "╭" else "┌",
                    .double, .double_dashed => if (self.options.rounded_corners) "╭" else "╔",
                };
                const top_right = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => if (self.options.rounded_corners) "╮" else "┐",
                    .double, .double_dashed => if (self.options.rounded_corners) "╮" else "╗",
                };
                const bottom_left = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => if (self.options.rounded_corners) "╰" else "└",
                    .double, .double_dashed => if (self.options.rounded_corners) "╰" else "╚",
                };
                const bottom_right = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => if (self.options.rounded_corners) "╯" else "┘",
                    .double, .double_dashed => if (self.options.rounded_corners) "╯" else "╝",
                };
                for (1..grid.size.width - 1) |x| {
                    if ((border_style == .single_dashed or border_style == .double_dashed) and x % 2 == 1) continue;
                    grid.cells.items[try grid.cells.at(.{ 0, x })].rune = horiz_line;
                    grid.cells.items[try grid.cells.at(.{ grid.size.height - 1, x })].rune = horiz_line;
                }
                grid.cells.items[try grid.cells.at(.{ 1, 0 })].rune = vert_line;
                grid.cells.items[try grid.cells.at(.{ 1, grid.size.width - 1 })].rune = vert_line;
                grid.cells.items[try grid.cells.at(.{ 0, 0 })].rune = top_left;
                grid.cells.items[try grid.cells.at(.{ 0, grid.size.width - 1 })].rune = top_right;
                grid.cells.items[try grid.cells.at(.{ grid.size.height - 1, 0 })].rune = bottom_left;
                grid.cells.items[try grid.cells.at(.{ grid.size.height - 1, grid.size.width - 1 })].rune = bottom_right;

                // overlay the label on the top border, truncating to fit
                if (self.options.label.len > 0 and grid.size.width > 2) {
                    var label_iter = (try std.unicode.Utf8View.init(self.options.label)).iterator();
                    var x: usize = 1;
                    while (label_iter.nextCodepointSlice()) |ch| {
                        if (x >= grid.size.width - 1) break;
                        grid.cells.items[try grid.cells.at(.{ 0, x })].rune = ch;
                        x += 1;
                    }
                }
            }

            self.grid = grid;
        }

        pub fn input(self: *TextInput(Widget), key: inp.Key, root_focus: *Focus) !void {
            _ = root_focus;
            switch (key) {
                .arrow_left => self.cursor -|= 1,
                .arrow_right => if (self.cursor < self.content.items.len) {
                    self.cursor += 1;
                },
                .home => self.cursor = 0,
                .end => self.cursor = self.content.items.len,
                .delete => if (self.cursor < self.content.items.len) {
                    const removed = self.content.orderedRemove(self.cursor);
                    self.allocator.free(removed);
                },
                .backspace => if (self.cursor > 0) {
                    const removed = self.content.orderedRemove(self.cursor - 1);
                    self.allocator.free(removed);
                    self.cursor -= 1;
                },
                .codepoint => |cp| {
                    // ignore control characters; only printable text is inserted
                    if (cp < 0x20) return;
                    var buf: [4]u8 = undefined;
                    const len = try std.unicode.utf8Encode(cp, &buf);
                    const owned = try self.allocator.dupe(u8, buf[0..len]);
                    errdefer self.allocator.free(owned);
                    try self.content.insert(self.allocator, self.cursor, owned);
                    self.cursor += 1;
                },
                else => {},
            }
        }

        pub fn clearGrid(self: *TextInput(Widget)) void {
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }

        pub fn getGrid(self: TextInput(Widget)) ?Grid {
            return self.grid;
        }

        pub fn getFocus(self: *TextInput(Widget)) *Focus {
            return &self.focus;
        }
    };
}

pub fn Scroll(comptime Widget: type) type {
    return struct {
        allocator: std.mem.Allocator,
        grid: ?Grid,
        child: *Widget,
        x: isize,
        y: isize,
        direction: Direction,

        pub const Direction = enum {
            vert,
            horiz,
            both,
        };

        pub fn init(allocator: std.mem.Allocator, widget: Widget, direction: Direction) !Scroll(Widget) {
            const child = try allocator.create(Widget);
            errdefer allocator.destroy(child);
            child.* = widget;
            return .{
                .allocator = allocator,
                .grid = null,
                .child = child,
                .x = 0,
                .y = 0,
                .direction = direction,
            };
        }

        pub fn deinit(self: *Scroll(Widget)) void {
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
            self.child.deinit();
            self.allocator.destroy(self.child);
        }

        pub fn build(self: *Scroll(Widget), constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            const child_constraint: layout.Constraint = switch (self.direction) {
                .vert => .{
                    .min_size = constraint.min_size,
                    .max_size = .{ .width = constraint.max_size.width, .height = null },
                },
                .horiz => .{
                    .min_size = constraint.min_size,
                    .max_size = .{ .width = null, .height = constraint.max_size.height },
                },
                .both => .{
                    .min_size = constraint.min_size,
                    .max_size = .{ .width = null, .height = null },
                },
            };
            try self.child.build(child_constraint, root_focus);
            if (self.child.getGrid()) |child_grid| {
                self.grid = try Grid.initFromGrid(self.allocator, child_grid, .{
                    .width = @max(1, @min(child_grid.size.width, constraint.max_size.width orelse child_grid.size.width)),
                    .height = @max(1, @min(child_grid.size.height, constraint.max_size.height orelse child_grid.size.height)),
                }, self.x, self.y);
            }
        }

        pub fn input(self: *Scroll(Widget), key: inp.Key, root_focus: *Focus) !void {
            try self.child.input(key, root_focus);
        }

        pub fn clearGrid(self: *Scroll(Widget)) void {
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }

        pub fn getGrid(self: Scroll(Widget)) ?Grid {
            return self.grid;
        }

        pub fn scrollToRect(self: *Scroll(Widget), rect: layout.IRect) void {
            if (self.grid) |grid| {
                if (self.direction == .horiz or self.direction == .both) {
                    if (rect.x < self.x) {
                        self.x -= self.x - rect.x;
                    } else {
                        const rect_x = rect.x + @as(isize, @intCast(rect.size.width));
                        const self_x = self.x + @as(isize, @intCast(grid.size.width));
                        self.x += if (rect_x > self_x)
                            rect_x - self_x
                        else
                            0;
                    }
                }
                if (self.direction == .vert or self.direction == .both) {
                    if (rect.y < self.y) {
                        self.y -= self.y - rect.y;
                    } else {
                        const rect_y = rect.y + @as(isize, @intCast(rect.size.height));
                        const self_y = self.y + @as(isize, @intCast(grid.size.height));
                        self.y += if (rect_y > self_y)
                            rect_y - self_y
                        else
                            0;
                    }
                }
            }
        }

        pub fn getFocus(self: *Scroll(Widget)) *Focus {
            return self.child.getFocus();
        }
    };
}

pub fn Stack(comptime Widget: type) type {
    return struct {
        focus: Focus,
        children: std.AutoArrayHashMapUnmanaged(usize, Widget),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Stack(Widget) {
            return .{
                .focus = Focus.init(allocator, .container),
                .children = .empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Stack(Widget)) void {
            self.focus.deinit();
            for (self.children.values()) |*child| {
                child.deinit();
            }
            self.children.deinit(self.allocator);
        }

        pub fn build(self: *Stack(Widget), constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            self.getFocus().clear();
            if (self.getSelected()) |selected_widget| {
                try selected_widget.build(constraint, root_focus);
                if (selected_widget.getGrid()) |child_grid| {
                    try self.getFocus().addChild(selected_widget.getFocus(), child_grid.size, 0, 0);
                }
            }
        }

        pub fn input(self: *Stack(Widget), key: inp.Key, root_focus: *Focus) !void {
            if (self.getSelected()) |selected_widget| {
                try selected_widget.input(key, root_focus);
            }
        }

        pub fn clearGrid(self: *Stack(Widget)) void {
            if (self.getSelected()) |selected_widget| {
                selected_widget.clearGrid();
            }
        }

        pub fn getGrid(self: Stack(Widget)) ?Grid {
            if (self.getSelected()) |selected_widget| {
                return selected_widget.getGrid();
            } else {
                return null;
            }
        }

        pub fn getFocus(self: *Stack(Widget)) *Focus {
            return &self.focus;
        }

        pub fn getSelected(self: Stack(Widget)) ?*Widget {
            if (self.focus.child_id) |child_id| {
                if (self.children.getIndex(child_id)) |current_index| {
                    return &self.children.values()[current_index];
                }
            }
            return null;
        }
    };
}
