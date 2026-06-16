const std = @import("std");
const Grid = @import("./grid.zig").Grid;
const Focus = @import("./focus.zig").Focus;
const layout = @import("./layout.zig");
const inp = @import("./input.zig");

pub fn Text(comptime Widget: type) type {
    return struct {
        focus: *Focus,
        grid: ?Grid,
        content: []const u8,

        pub fn init(allocator: std.mem.Allocator, content: []const u8) !Text(Widget) {
            return .{
                .focus = try Focus.create(allocator, .text),
                .grid = null,
                .content = content,
            };
        }

        pub fn deinit(self: *Text(Widget), allocator: std.mem.Allocator) void {
            self.focus.destroy(allocator);
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }

        pub fn build(self: *Text(Widget), allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            _ = root_focus;
            self.clearGrid();
            // a zero-width or zero-height budget means render nothing
            if (constraint.max_size.width) |max_width| {
                if (max_width == 0) return;
            }
            if (constraint.max_size.height) |max_height| {
                if (max_height == 0) return;
            }
            const width = try std.unicode.utf8CountCodepoints(self.content);
            var grid = try Grid.init(allocator, .{ .width = @max(1, @min(width, constraint.max_size.width orelse width)), .height = 1 });
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

        pub fn input(self: *Text(Widget), allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
            _ = self;
            _ = allocator;
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
            return self.focus;
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
        focus: *Focus,
        grid: ?Grid,
        children: std.AutoArrayHashMapUnmanaged(usize, Child),
        options: Options,

        pub const Child = struct {
            widget: Widget,
            rect: ?layout.IRect,
            min_size: ?layout.MaybeSize,
            max_size: ?layout.MaybeSize = null,
            // flex-shrink: a shrink child yields main-axis space to its
            // siblings, taking only the leftover after their minimums and
            // clipping to it (to nothing if need be). the box measures the child
            // at that budget and pins its size for the rest of layout, so it
            // behaves as a fixed-size child here — leave min_size/max_size null;
            // they're overwritten.
            shrink: bool = false,
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
                .focus = try Focus.create(allocator, .container),
                .grid = null,
                .children = .empty,
                .options = options,
            };
        }

        pub fn deinit(self: *Box(Widget), allocator: std.mem.Allocator) void {
            self.focus.destroy(allocator);
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
            for (self.children.values()) |*child| {
                child.widget.deinit(allocator);
            }
            self.children.deinit(allocator);
        }

        pub fn build(self: *Box(Widget), allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();

            const border_size: usize = if (self.options.border_style) |_| 1 else 0;
            if (constraint.max_size.width) |max_width| {
                if (max_width <= border_size * 2) return;
            }
            if (constraint.max_size.height) |max_height| {
                if (max_height <= border_size * 2) return;
            }

            var sorted_children: std.AutoArrayHashMapUnmanaged(usize, void) = .empty;
            defer sorted_children.deinit(allocator);
            var should_sort = false;
            for (self.children.values(), 0..) |child, i| {
                try sorted_children.put(allocator, i, {});
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

            // budget for flex-shrink children along the main axis: the inner
            // size left once every other child has its minimum. null when there's
            // no shrink child or the main axis is unbounded.
            const shrink_budget: ?usize = blk: {
                var any_shrink = false;
                for (self.children.values()) |child| {
                    if (child.shrink) {
                        any_shrink = true;
                        break;
                    }
                }
                if (!any_shrink) break :blk null;
                const main_remaining = switch (self.options.direction) {
                    .horiz => remaining_width_maybe,
                    .vert => remaining_height_maybe,
                } orelse break :blk null;
                var others: usize = 0;
                for (self.children.values()) |child| {
                    if (child.shrink) continue;
                    if (child.min_size) |min_size| {
                        const min_main = switch (self.options.direction) {
                            .horiz => min_size.width,
                            .vert => min_size.height,
                        };
                        others += min_main orelse 0;
                    }
                }
                break :blk main_remaining -| others;
            };

            // measure each flex-shrink child at the budget, then pin it to the
            // result (min == max). for the rest of the layout it then behaves like
            // a fixed-size child: siblings reserve room for it and it can't
            // over-consume, regardless of the order children get built in.
            // measuring (building at the budget) yields min(natural, budget), so
            // the child clips when the leftover is tight and disappears at zero —
            // yielding before any sibling is dropped.
            if (shrink_budget) |budget| {
                for (self.children.values()) |*child| {
                    if (!child.shrink) continue;
                    const measure_max: layout.MaybeSize = switch (self.options.direction) {
                        .horiz => .{ .width = budget, .height = remaining_height_maybe },
                        .vert => .{ .width = remaining_width_maybe, .height = budget },
                    };
                    try child.widget.build(allocator, .{
                        .min_size = .{ .width = null, .height = null },
                        .max_size = measure_max,
                    }, root_focus);
                    const measured: usize = if (child.widget.getGrid()) |grid| switch (self.options.direction) {
                        .horiz => grid.size.width,
                        .vert => grid.size.height,
                    } else 0;
                    child.min_size = switch (self.options.direction) {
                        .horiz => .{ .width = measured, .height = null },
                        .vert => .{ .width = null, .height = measured },
                    };
                    child.max_size = child.min_size;
                }
            }

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

                // reserve room for the children built after this one so a greedy
                // child (e.g. a Spacer that fills its max) leaves space for their
                // minimums rather than starving them. this runs for every child: a
                // child with no min_size of its own reserves as if that minimum
                // were 0, so a fill widget needn't declare a min just to be a
                // well-behaved sibling.
                var expected_remaining_width_maybe = remaining_width_maybe;
                var expected_remaining_height_maybe = remaining_height_maybe;
                var child_min_size: layout.MaybeSize = child.min_size orelse .{ .width = null, .height = null };
                if (expected_remaining_width_maybe) |*expected_remaining_width| {
                    const self_min_width = child_min_size.width orelse 0;
                    for (sorted_child_index + 1..sorted_children.count()) |next_sorted_child_index| {
                        const next_child = &self.children.values()[sorted_children.keys()[next_sorted_child_index]];
                        if (next_child.min_size) |next_min_size| {
                            if (next_min_size.width) |next_min_width| {
                                if (expected_remaining_width.* >= self_min_width + next_min_width) {
                                    expected_remaining_width.* -= next_min_width;
                                }
                            }
                        }
                    }
                }
                if (expected_remaining_height_maybe) |*expected_remaining_height| {
                    const self_min_height = child_min_size.height orelse 0;
                    for (sorted_child_index + 1..sorted_children.count()) |next_sorted_child_index| {
                        const next_child = &self.children.values()[sorted_children.keys()[next_sorted_child_index]];
                        if (next_child.min_size) |next_min_size| {
                            if (next_min_size.height) |next_min_height| {
                                if (expected_remaining_height.* >= self_min_height + next_min_height) {
                                    expected_remaining_height.* -= next_min_height;
                                }
                            }
                        }
                    }
                }

                // propagate whatever's left of our parent's min-size to the
                // last child along our primary axis. a shrink child is exempt:
                // it's meant to yield space, not be forced to fill it.
                if (sorted_child_index + 1 == sorted_children.count() and !child.shrink) {
                    switch (self.options.direction) {
                        .vert => if (constraint.min_size.height) |min_h| {
                            const inner_min = if (min_h > border_size * 2) min_h - border_size * 2 else 0;
                            if (inner_min > height) {
                                const remaining = inner_min - height;
                                if (remaining > (child_min_size.height orelse 0)) {
                                    child_min_size.height = remaining;
                                }
                            }
                        },
                        .horiz => if (constraint.min_size.width) |min_w| {
                            const inner_min = if (min_w > border_size * 2) min_w - border_size * 2 else 0;
                            if (inner_min > width) {
                                const remaining = inner_min - width;
                                if (remaining > (child_min_size.width orelse 0)) {
                                    child_min_size.width = remaining;
                                }
                            }
                        },
                    }
                }

                // clamp the granted max size by any per-child cap so the
                // child can't grow past its declared limit even if there's
                // more room available in the parent.
                const child_max_width = clampMax(expected_remaining_width_maybe, if (child.max_size) |ms| ms.width else null);
                const child_max_height = clampMax(expected_remaining_height_maybe, if (child.max_size) |ms| ms.height else null);

                try child.widget.build(allocator, .{
                    .min_size = child_min_size,
                    .max_size = .{ .width = child_max_width, .height = child_max_height },
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

            var grid = try Grid.init(allocator, .{ .width = width, .height = height });
            errdefer grid.deinit();

            self.getFocus().clear();

            switch (self.options.direction) {
                .vert => {
                    var line: usize = 0;
                    for (self.children.values()) |*child| {
                        if (child.widget.getGrid()) |child_grid| {
                            child.rect = .{ .x = 0, .y = @as(isize, @intCast(line + border_size)), .size = child_grid.size };
                            try grid.drawGrid(child_grid, border_size, line + border_size);
                            try self.getFocus().addChild(allocator, child.widget.getFocus(), child_grid.size, border_size, line + border_size);
                            line += child_grid.size.height;
                        } else {
                            // this child wasn't laid out this build (it didn't fit,
                            // so it has no grid). drop its stale focus subtree so it
                            // isn't flattened upward, which would leave phantom
                            // focusables/scrolls behind from when it was last shown.
                            child.widget.getFocus().clear();

                            try self.getFocus().addChild(allocator, child.widget.getFocus(), .{ .width = 0, .height = 0 }, 0, 0);
                        }
                    }
                },
                .horiz => {
                    var col: usize = 0;
                    for (self.children.values()) |*child| {
                        if (child.widget.getGrid()) |child_grid| {
                            child.rect = .{ .x = @as(isize, @intCast(col + border_size)), .y = 0, .size = child_grid.size };
                            try grid.drawGrid(child_grid, col + border_size, border_size);
                            try self.getFocus().addChild(allocator, child.widget.getFocus(), child_grid.size, col + border_size, border_size);
                            col += child_grid.size.width;
                        } else {
                            // this child wasn't laid out this build (it didn't fit,
                            // so it has no grid). drop its stale focus subtree so it
                            // isn't flattened upward, which would leave phantom
                            // focusables/scrolls behind from when it was last shown.
                            child.widget.getFocus().clear();

                            try self.getFocus().addChild(allocator, child.widget.getFocus(), .{ .width = 0, .height = 0 }, 0, 0);
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

        pub fn input(self: *Box(Widget), allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
            for (self.children.values()) |*child| {
                try child.widget.input(allocator, key, root_focus);
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
            return self.focus;
        }

        fn clampMax(parent_max: ?usize, child_max: ?usize) ?usize {
            if (parent_max) |p| {
                if (child_max) |c| return @min(p, c);
                return p;
            }
            return child_max;
        }
    };
}

pub const WrapKind = enum {
    none,
    // break lines anywhere; one codepoint past the edge wraps to the next row
    char,
    // break lines at whitespace; a single token longer than the line falls
    // back to char-wrapping just that token
    word,
};

pub fn TextBox(comptime Widget: type) type {
    return struct {
        box: Box(Widget),
        options: Options,
        last_wrap_width: ?usize,
        content: []const u8,
        lines: std.ArrayList([]const u8),

        pub const Options = struct {
            border_style: ?BorderStyle,
            rounded_corners: bool = false,
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
            errdefer box.deinit(allocator);
            box.getFocus().kind = .text_box;
            for (lines.items) |line| {
                var text = try Text(Widget).init(allocator, line);
                errdefer text.deinit(allocator);
                try box.children.put(allocator, text.getFocus().id, .{ .widget = .{ .text = text }, .rect = null, .min_size = null });
            }

            return .{
                .box = box,
                .options = options,
                .last_wrap_width = null,
                .content = content,
                .lines = lines,
            };
        }

        pub fn deinit(self: *TextBox(Widget), allocator: std.mem.Allocator) void {
            self.box.deinit(allocator);
            for (self.lines.items) |line| {
                allocator.free(line);
            }
            self.lines.deinit(allocator);
        }

        pub fn build(self: *TextBox(Widget), allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            if (self.options.wrap_kind != .none) {
                if (constraint.max_size.width) |max_width| {
                    const should_rewrap = if (self.last_wrap_width) |last_wrap_width| last_wrap_width != max_width else true;
                    self.last_wrap_width = max_width;

                    if (should_rewrap) {
                        const border_size: usize = if (self.options.border_style) |_| 1 else 0;
                        const inner_width: usize = if (max_width > border_size * 2) max_width - border_size * 2 else 0;

                        for (self.lines.items) |line| allocator.free(line);
                        self.lines.clearAndFree(allocator);

                        switch (self.options.wrap_kind) {
                            .none => unreachable,
                            .char => {
                                var line: std.ArrayList(u8) = .empty;
                                errdefer line.deinit(allocator);

                                var utf8 = (try std.unicode.Utf8View.init(self.content)).iterator();
                                while (utf8.nextCodepointSlice()) |char| {
                                    if (std.mem.eql(u8, char, "\n")) {
                                        try self.lines.append(allocator, try line.toOwnedSlice(allocator));
                                    } else {
                                        try line.appendSlice(allocator, char);
                                    }

                                    if (std.mem.eql(u8, utf8.peek(1), "")) {
                                        try self.lines.append(allocator, try line.toOwnedSlice(allocator));
                                    } else if (try std.unicode.utf8CountCodepoints(line.items) == inner_width) {
                                        try self.lines.append(allocator, try line.toOwnedSlice(allocator));
                                    }
                                }
                            },
                            .word => {
                                var line: std.ArrayList(u8) = .empty;
                                errdefer line.deinit(allocator);
                                var line_cp: usize = 0;

                                var word: std.ArrayList(u8) = .empty;
                                defer word.deinit(allocator);
                                var word_cp: usize = 0;

                                var utf8 = (try std.unicode.Utf8View.init(self.content)).iterator();
                                while (utf8.nextCodepointSlice()) |cp| {
                                    const is_newline = std.mem.eql(u8, cp, "\n");
                                    const is_space = std.mem.eql(u8, cp, " ") or std.mem.eql(u8, cp, "\t");

                                    if (is_newline or is_space) {
                                        try flushPendingWord(allocator, &self.lines, &line, &line_cp, &word, &word_cp, inner_width);
                                    }

                                    if (is_newline) {
                                        try self.lines.append(allocator, try line.toOwnedSlice(allocator));
                                        line_cp = 0;
                                    } else if (is_space) {
                                        // collapse spaces at the start of a line; otherwise keep
                                        // the separator and drop trailing spaces past the edge.
                                        if (line_cp > 0 and line_cp < inner_width) {
                                            try line.appendSlice(allocator, cp);
                                            line_cp += 1;
                                        }
                                    } else {
                                        try word.appendSlice(allocator, cp);
                                        word_cp += 1;
                                    }

                                    if (std.mem.eql(u8, utf8.peek(1), "")) {
                                        try flushPendingWord(allocator, &self.lines, &line, &line_cp, &word, &word_cp, inner_width);
                                        try self.lines.append(allocator, try line.toOwnedSlice(allocator));
                                        line_cp = 0;
                                    }
                                }
                            },
                        }

                        // refresh the inner box's children in-place
                        for (self.box.children.values()) |*child| child.widget.deinit(allocator);
                        self.box.children.clearAndFree(allocator);
                        for (self.lines.items) |line| {
                            var text = try Text(Widget).init(allocator, line);
                            errdefer text.deinit(allocator);
                            try self.box.children.put(allocator, text.getFocus().id, .{ .widget = .{ .text = text }, .rect = null, .min_size = null });
                        }
                    }
                }
            }

            self.clearGrid();
            // update border to reflect focus
            const focused = root_focus.grandchild_id == self.getFocus().id;
            self.box.options.border_style = if (self.options.border_style) |base| switch (base) {
                .single => if (focused) .double else .single,
                .single_dashed => if (focused) .double_dashed else .single_dashed,
                .hidden, .double, .double_dashed => base,
            } else null;
            self.box.options.rounded_corners = self.options.rounded_corners;
            try self.box.build(allocator, constraint, root_focus);
        }

        pub fn input(self: *TextBox(Widget), allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
            try self.box.input(allocator, key, root_focus);
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

        fn flushPendingWord(
            allocator: std.mem.Allocator,
            lines: *std.ArrayList([]const u8),
            line: *std.ArrayList(u8),
            line_cp: *usize,
            word: *std.ArrayList(u8),
            word_cp: *usize,
            inner_width: usize,
        ) !void {
            if (word_cp.* == 0) return;

            if (line_cp.* + word_cp.* <= inner_width) {
                try line.appendSlice(allocator, word.items);
                line_cp.* += word_cp.*;
            } else if (word_cp.* <= inner_width) {
                // wrap to a fresh line so the word stays intact
                if (line_cp.* > 0) {
                    try lines.append(allocator, try line.toOwnedSlice(allocator));
                    line_cp.* = 0;
                }
                try line.appendSlice(allocator, word.items);
                line_cp.* = word_cp.*;
            } else {
                // word is longer than a whole line — fall back to char-wrap so
                // it at least renders rather than disappearing past the edge.
                if (line_cp.* > 0) {
                    try lines.append(allocator, try line.toOwnedSlice(allocator));
                    line_cp.* = 0;
                }
                var w_utf8 = (try std.unicode.Utf8View.init(word.items)).iterator();
                while (w_utf8.nextCodepointSlice()) |c| {
                    if (line_cp.* == inner_width) {
                        try lines.append(allocator, try line.toOwnedSlice(allocator));
                        line_cp.* = 0;
                    }
                    try line.appendSlice(allocator, c);
                    line_cp.* += 1;
                }
            }

            word.clearRetainingCapacity();
            word_cp.* = 0;
        }
    };
}

pub fn TextInput(comptime Widget: type) type {
    return struct {
        focus: *Focus,
        grid: ?Grid,
        content: std.ArrayList([]const u8),
        cursor: usize,
        scroll_offset: usize,
        options: Options,

        pub const Options = struct {
            border_style: ?BorderStyle = .single_dashed,
            rounded_corners: bool = false,
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
            // when false, the content (and cursor) aren't drawn into the grid
            render_content: bool = true,
        };

        pub fn init(allocator: std.mem.Allocator, options: Options) !TextInput(Widget) {
            return .{
                .focus = try Focus.create(allocator, if (options.password) .text_input_password else .text_input),
                .grid = null,
                .content = .empty,
                .cursor = 0,
                .scroll_offset = 0,
                .options = options,
            };
        }

        pub fn deinit(self: *TextInput(Widget), allocator: std.mem.Allocator) void {
            self.focus.destroy(allocator);
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
            for (self.content.items) |cp| allocator.free(cp);
            self.content.deinit(allocator);
        }

        // replaces all typed content with the codepoints in `bytes`, dropping
        // existing allocations. cursor lands at the end so subsequent edits
        // (or rendering) treat the supplied text as the new state.
        pub fn setContent(self: *TextInput(Widget), allocator: std.mem.Allocator, bytes: []const u8) !void {
            for (self.content.items) |cp| allocator.free(cp);
            self.content.clearAndFree(allocator);

            var utf8 = (try std.unicode.Utf8View.init(bytes)).iterator();
            while (utf8.nextCodepointSlice()) |cp_slice| {
                const owned = try allocator.dupe(u8, cp_slice);
                errdefer allocator.free(owned);
                try self.content.append(allocator, owned);
            }

            self.cursor = self.content.items.len;
            self.scroll_offset = 0;
        }

        pub fn clear(self: *TextInput(Widget), allocator: std.mem.Allocator) void {
            for (self.content.items) |cp| allocator.free(cp);
            self.content.clearAndFree(allocator);
            self.cursor = 0;
            self.scroll_offset = 0;
        }

        // concatenates the stored codepoint slices into a single owned buffer
        pub fn text(self: *const TextInput(Widget), allocator: std.mem.Allocator) ![]u8 {
            var total: usize = 0;
            for (self.content.items) |cp| total += cp.len;
            const buf = try allocator.alloc(u8, total);
            var i: usize = 0;
            for (self.content.items) |cp| {
                @memcpy(buf[i .. i + cp.len], cp);
                i += cp.len;
            }
            return buf;
        }

        pub fn build(self: *TextInput(Widget), allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
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

            var grid = try Grid.init(allocator, .{ .width = width, .height = height });
            errdefer grid.deinit();

            const has_focus = root_focus.grandchild_id == self.focus.id;

            // text + cursor (skipped when an external overlay owns the display)
            if (self.options.render_content) {
                for (0..inner_width) |i| {
                    const content_index = self.scroll_offset + i;
                    const cell_x = i + border_size;
                    const cell_y = border_size;
                    const cell_idx = try grid.cells.at(.{ cell_y, cell_x });
                    if (content_index < self.content.items.len) {
                        grid.cells.items[cell_idx].rune = if (self.options.password) "•" else self.content.items[content_index];
                    } else if (content_index == self.content.items.len and self.cursor == content_index and has_focus) {
                        // cursor sits past the last char — paint a space underneath
                        grid.cells.items[cell_idx].rune = " ";
                    }
                    if (content_index == self.cursor and has_focus) {
                        grid.cells.items[cell_idx].style.inverted = true;
                        if (grid.cells.items[cell_idx].rune == null) {
                            grid.cells.items[cell_idx].rune = " ";
                        }
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

        pub fn input(self: *TextInput(Widget), allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
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
                    allocator.free(removed);
                },
                .backspace => if (self.cursor > 0) {
                    const removed = self.content.orderedRemove(self.cursor - 1);
                    allocator.free(removed);
                    self.cursor -= 1;
                },
                .codepoint => |cp| {
                    // ignore control characters; only printable text is inserted
                    if (cp < 0x20) return;
                    var buf: [4]u8 = undefined;
                    const len = try std.unicode.utf8Encode(cp, &buf);
                    const owned = try allocator.dupe(u8, buf[0..len]);
                    errdefer allocator.free(owned);
                    try self.content.insert(allocator, self.cursor, owned);
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
            return self.focus;
        }
    };
}

pub const ScrollDirection = enum {
    vert,
    horiz,
    both,
};

pub fn Scroll(comptime Widget: type) type {
    return struct {
        grid: ?Grid,
        child: *Widget,
        x: isize,
        y: isize,
        options: Options,
        // columns/rows the scroll bar actually occupied on the last build. zero
        // when the content fit and no bar was drawn; used to keep scrollToRect's
        // viewport math in sync with what was rendered.
        bar_w: usize,
        bar_h: usize,

        // the solid run that represents the visible portion of the content.
        const thumb_rune = "█";
        // the lighter run drawn behind the thumb for the rest of the bar.
        const track_rune = "░";

        pub const Options = struct {
            direction: ScrollDirection = .vert,
            show_bar: bool = true,
            // when true, expose the full unclipped content (and skip the text
            // scrollbar and focus-rect clipping) so a web renderer can place the
            // content in a natively-scrollable element
            web_native: bool = false,
        };

        // subtract a scroll bar's reserved column/row from an optional size
        // constraint, keeping at least one cell. a null (unbounded) size stays null.
        fn subReserve(size: ?usize, reserve: usize) ?usize {
            return if (size) |s| (if (s > reserve) s - reserve else 1) else null;
        }

        // figure out where the scroll bar thumb sits and how long it is. the thumb's
        // length is the track length scaled by how much of the content is visible, and
        // its position is the current scroll offset scaled into the leftover track. if
        // everything fits, the thumb fills the whole track.
        fn scrollBarThumb(track_len: usize, content_total: usize, viewport: usize, offset: isize) struct { start: usize, len: usize } {
            if (track_len == 0 or content_total <= viewport) {
                return .{ .start = 0, .len = track_len };
            }
            const tl: f64 = @floatFromInt(track_len);
            const ct: f64 = @floatFromInt(content_total);
            const vp: f64 = @floatFromInt(viewport);
            var len: usize = @intFromFloat(@round(tl * vp / ct));
            if (len < 1) len = 1;
            if (len > track_len) len = track_len;
            const max_start = track_len - len;
            const off: f64 = @floatFromInt(@max(@as(isize, 0), offset));
            const max_off = ct - vp;
            var start: usize = @intFromFloat(@round(@as(f64, @floatFromInt(max_start)) * off / max_off));
            if (start > max_start) start = max_start;
            return .{ .start = start, .len = len };
        }

        // the constraint to lay the child out under, shrinking the bounded axis
        // by the column/row each bar reserves so content never sits under it.
        fn childConstraint(direction: ScrollDirection, constraint: layout.Constraint, reserve_w: usize, reserve_h: usize) layout.Constraint {
            return switch (direction) {
                .vert => .{
                    .min_size = constraint.min_size,
                    .max_size = .{ .width = subReserve(constraint.max_size.width, reserve_w), .height = null },
                },
                .horiz => .{
                    .min_size = constraint.min_size,
                    .max_size = .{ .width = null, .height = subReserve(constraint.max_size.height, reserve_h) },
                },
                .both => .{
                    .min_size = constraint.min_size,
                    .max_size = .{ .width = null, .height = null },
                },
            };
        }

        pub fn init(allocator: std.mem.Allocator, widget: Widget, options: Options) !Scroll(Widget) {
            const child = try allocator.create(Widget);
            errdefer allocator.destroy(child);
            child.* = widget;
            return .{
                .grid = null,
                .child = child,
                .x = 0,
                .y = 0,
                .options = options,
                .bar_w = 0,
                .bar_h = 0,
            };
        }

        pub fn deinit(self: *Scroll(Widget), allocator: std.mem.Allocator) void {
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
            self.child.deinit(allocator);
            allocator.destroy(self.child);
        }

        pub fn build(self: *Scroll(Widget), allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            self.bar_w = 0;
            self.bar_h = 0;

            // lay the child out at the full viewport first so we can tell whether
            // it actually overflows. a bar (and the column/row it steals) is only
            // worth showing when the content doesn't fit.
            const dir = self.options.direction;
            try self.child.build(allocator, childConstraint(dir, constraint, 0, 0), root_focus);

            // web-native mode: the browser scrolls a real element holding the
            // full content, so keep self.grid only as the viewport footprint (for
            // the parent's layout), hand the full child grid to the renderer via
            // the focus node, and leave the child's focus rects in content space
            // (no clip/shift) and draw no scrollbar.
            if (self.options.web_native) {
                if (self.child.getGrid()) |child_grid| {
                    const avail_w = constraint.max_size.width orelse child_grid.size.width;
                    const avail_h = constraint.max_size.height orelse child_grid.size.height;
                    const content_w = @max(1, @min(child_grid.size.width, avail_w));
                    const content_h = @max(1, @min(child_grid.size.height, avail_h));
                    self.grid = try Grid.initFromGrid(allocator, child_grid, .{ .width = content_w, .height = content_h }, 0, 0);
                    self.getFocus().scroll = .{
                        .content = child_grid,
                        .offset_x = self.x,
                        .offset_y = self.y,
                        .direction = dir,
                    };
                }
                return;
            }

            if (self.child.getGrid()) |measured| {
                const vp_w = constraint.max_size.width orelse measured.size.width;
                const vp_h = constraint.max_size.height orelse measured.size.height;
                const can_vert = dir == .vert or dir == .both;
                const can_horiz = dir == .horiz or dir == .both;

                // a bar shrinks the cross viewport by one, which can tip the other
                // axis into overflowing; resolve both together. content size is
                // fixed for .both (unbounded child) and the cross axis doesn't
                // affect overflow for single-direction scrolls, so this settles in
                // one pass.
                var reserve_w: usize = 0;
                var reserve_h: usize = 0;
                if (self.options.show_bar) {
                    for (0..2) |_| {
                        reserve_w = if (can_vert and measured.size.height > vp_h -| reserve_h) 1 else 0;
                        reserve_h = if (can_horiz and measured.size.width > vp_w -| reserve_w) 1 else 0;
                    }
                }

                // re-lay the child in the reduced space so it wraps/clips to the
                // area left beside the bar. (.both leaves the child unbounded, so
                // there's nothing to redo.)
                if ((reserve_w != 0 or reserve_h != 0) and dir != .both) {
                    try self.child.build(allocator, childConstraint(dir, constraint, reserve_w, reserve_h), root_focus);
                }
                self.bar_w = reserve_w;
                self.bar_h = reserve_h;
            }

            if (self.child.getGrid()) |child_grid| {
                const reserve_w = self.bar_w;
                const reserve_h = self.bar_h;
                const avail_w = subReserve(constraint.max_size.width, reserve_w) orelse child_grid.size.width;
                const avail_h = subReserve(constraint.max_size.height, reserve_h) orelse child_grid.size.height;
                const content_w = @max(1, @min(child_grid.size.width, avail_w));
                const content_h = @max(1, @min(child_grid.size.height, avail_h));

                if (reserve_w == 0 and reserve_h == 0) {
                    self.grid = try Grid.initFromGrid(allocator, child_grid, .{
                        .width = content_w,
                        .height = content_h,
                    }, self.x, self.y);
                } else {
                    // draw the scrolled content into a grid that's one wider
                    // and/or one taller than the content area, then paint the
                    // bar(s) into the reserved column/row.
                    var content = try Grid.initFromGrid(allocator, child_grid, .{
                        .width = content_w,
                        .height = content_h,
                    }, self.x, self.y);
                    defer content.deinit();
                    var full = try Grid.init(allocator, .{
                        .width = content_w + reserve_w,
                        .height = content_h + reserve_h,
                    });
                    errdefer full.deinit();
                    try full.drawGrid(content, 0, 0);
                    if (reserve_w == 1) {
                        const thumb = scrollBarThumb(content_h, child_grid.size.height, content_h, self.y);
                        const bar_x = content_w;
                        for (0..content_h) |row| {
                            full.cells.items[try full.cells.at(.{ row, bar_x })].rune =
                                if (row >= thumb.start and row < thumb.start + thumb.len) thumb_rune else track_rune;
                        }
                    }
                    if (reserve_h == 1) {
                        const thumb = scrollBarThumb(content_w, child_grid.size.width, content_w, self.x);
                        const bar_y = content_h;
                        for (0..content_w) |col| {
                            full.cells.items[try full.cells.at(.{ bar_y, col })].rune =
                                if (col >= thumb.start and col < thumb.start + thumb.len) thumb_rune else track_rune;
                        }
                    }
                    self.grid = full;
                }

                // the child registered its focusable descendants at content-space
                // coordinates; shift them into the viewport (by the scroll offset)
                // and clip to the visible area so click hit-testing lines up with
                // what's drawn. anything scrolled out of view becomes zero-size,
                // which never matches a hit-test.
                const view_w: isize = @intCast(content_w);
                const view_h: isize = @intCast(content_h);
                var iter = self.getFocus().children.iterator();
                while (iter.next()) |entry| {
                    const r = &entry.value_ptr.rect;
                    const x0 = @max(@as(isize, @intCast(r.x)) - self.x, 0);
                    const y0 = @max(@as(isize, @intCast(r.y)) - self.y, 0);
                    const x1 = @min(@as(isize, @intCast(r.x + r.size.width)) - self.x, view_w);
                    const y1 = @min(@as(isize, @intCast(r.y + r.size.height)) - self.y, view_h);
                    r.* = if (x1 > x0 and y1 > y0)
                        .{ .x = @intCast(x0), .y = @intCast(y0), .size = .{ .width = @intCast(x1 - x0), .height = @intCast(y1 - y0) } }
                    else
                        .{ .x = 0, .y = 0, .size = .{ .width = 0, .height = 0 } };
                }
            }
        }

        pub fn input(self: *Scroll(Widget), allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
            try self.child.input(allocator, key, root_focus);
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
                // the bar's reserved column/row isn't part of the content
                // viewport, so exclude it when computing scroll bounds.
                const content_width = grid.size.width - self.bar_w;
                const content_height = grid.size.height - self.bar_h;
                if (self.options.direction == .horiz or self.options.direction == .both) {
                    if (rect.x < self.x) {
                        self.x -= self.x - rect.x;
                    } else {
                        const rect_x = rect.x + @as(isize, @intCast(rect.size.width));
                        const self_x = self.x + @as(isize, @intCast(content_width));
                        self.x += if (rect_x > self_x)
                            rect_x - self_x
                        else
                            0;
                    }
                }
                if (self.options.direction == .vert or self.options.direction == .both) {
                    if (rect.y < self.y) {
                        self.y -= self.y - rect.y;
                    } else {
                        const rect_y = rect.y + @as(isize, @intCast(rect.size.height));
                        const self_y = self.y + @as(isize, @intCast(content_height));
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
        focus: *Focus,
        children: std.AutoArrayHashMapUnmanaged(usize, Widget),

        pub fn init(allocator: std.mem.Allocator) !Stack(Widget) {
            return .{
                .focus = try Focus.create(allocator, .container),
                .children = .empty,
            };
        }

        pub fn deinit(self: *Stack(Widget), allocator: std.mem.Allocator) void {
            self.focus.destroy(allocator);
            for (self.children.values()) |*child| {
                child.deinit(allocator);
            }
            self.children.deinit(allocator);
        }

        pub fn build(self: *Stack(Widget), allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            self.getFocus().clear();
            if (self.getSelected()) |selected_widget| {
                try selected_widget.build(allocator, constraint, root_focus);
                if (selected_widget.getGrid()) |child_grid| {
                    try self.getFocus().addChild(allocator, selected_widget.getFocus(), child_grid.size, 0, 0);
                }
            }
        }

        pub fn input(self: *Stack(Widget), allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
            if (self.getSelected()) |selected_widget| {
                try selected_widget.input(allocator, key, root_focus);
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
            return self.focus;
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
