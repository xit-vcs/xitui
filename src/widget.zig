const std = @import("std");
const Grid = @import("./grid.zig").Grid;
const Focus = @import("./focus.zig").Focus;
const layout = @import("./layout.zig");
const inp = @import("./input.zig");
const wth = @import("./width.zig");
const draw = @import("./draw.zig");

pub const BorderStyle = draw.BorderStyle;

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
            self.clearGrid();
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
            // measure in display columns, not codepoints: wide (e.g. CJK)
            // runes occupy two cells
            const content_width = try wth.displayWidth(self.content);
            var grid = try Grid.init(allocator, .{ .width = @max(1, @min(content_width, constraint.max_size.width orelse content_width)), .height = 1 });
            errdefer grid.deinit();
            var utf8 = (try std.unicode.Utf8View.init(self.content)).iterator();
            var i: usize = 0;
            while (utf8.nextCodepoint()) |char| {
                const w = wth.cellWidth(char);
                if (i + w > grid.size.width) {
                    break;
                }
                try grid.setRune(i, 0, char);
                i += w;
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

pub fn Box(comptime Widget: type) type {
    return struct {
        focus: *Focus,
        grid: ?Grid,
        children: std.AutoArrayHashMapUnmanaged(usize, Child),
        options: Options,

        pub const Flex = enum {
            none,
            shrink,
            grow,
        };

        pub const Child = struct {
            widget: Widget,
            rect: ?layout.IRect,
            min_size: ?layout.MaybeSize,
            max_size: ?layout.MaybeSize = null,
            // flexible children yield space or fill the space left along the
            // main axis. leave min_size/max_size null; they're overwritten.
            flex: Flex = .none,
            // skipped this build: occupies no space and isn't drawn, as if it
            // produced no grid. its focus subtree drops out too.
            hidden: bool = false,
        };

        pub const Direction = enum {
            vert,
            horiz,
        };

        pub const Options = struct {
            border_style: ?draw.BorderStyle,
            rounded_corners: bool = false,
            direction: Direction,
            // optional labels rendered over the top and bottom borders.
            label: []const u8 = "",
            bottom_label: []const u8 = "",
            // force each child to fill the cross axis when it's bounded.
            stretch: bool = false,
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
            self.clearGrid();
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

            const LayoutChild = struct {
                index: usize,
                min_size: layout.MaybeSize,
                max_size: layout.MaybeSize,
            };
            const no_size: layout.MaybeSize = .{ .width = null, .height = null };
            var layout_order: std.ArrayList(LayoutChild) = .empty;
            defer layout_order.deinit(allocator);
            var grow_count: usize = 0;
            var should_sort = false;
            for (self.children.values(), 0..) |child, i| {
                if (child.flex == .grow) {
                    if (!child.hidden) grow_count += 1;
                    continue;
                }
                try layout_order.append(allocator, .{
                    .index = i,
                    .min_size = child.min_size orelse no_size,
                    .max_size = child.max_size orelse no_size,
                });
                if (child.min_size != null) {
                    should_sort = true;
                }
            }
            if (should_sort) {
                const SortCtx = struct {
                    selected_index: usize,

                    pub fn lessThan(ctx: @This(), a: LayoutChild, b: LayoutChild) bool {
                        const ia: isize = @intCast(a.index);
                        const ib: isize = @intCast(b.index);
                        const a_priority = if (ia <= ctx.selected_index) ia else -ia;
                        const b_priority = if (ib <= ctx.selected_index) ib else -ib;
                        return a_priority > b_priority;
                    }
                };
                if (self.getFocus().child_id) |child_id| {
                    if (self.children.getIndex(child_id)) |index| {
                        std.mem.sort(LayoutChild, layout_order.items, SortCtx{ .selected_index = index }, SortCtx.lessThan);
                    }
                }
            }
            for (self.children.values(), 0..) |child, i| {
                if (child.flex != .grow) continue;
                try layout_order.append(allocator, .{
                    .index = i,
                    .min_size = child.min_size orelse no_size,
                    .max_size = child.max_size orelse no_size,
                });
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
                for (layout_order.items) |layout_child| {
                    const child = self.children.values()[layout_child.index];
                    if (child.flex == .shrink) {
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
                for (layout_order.items) |layout_child| {
                    const child = self.children.values()[layout_child.index];
                    if (child.hidden) continue;
                    if (child.flex == .shrink) continue;
                    const min_main = switch (self.options.direction) {
                        .horiz => layout_child.min_size.width,
                        .vert => layout_child.min_size.height,
                    };
                    others += min_main orelse 0;
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
                for (layout_order.items) |*layout_child| {
                    const child = &self.children.values()[layout_child.index];
                    if (child.hidden) continue;
                    if (child.flex != .shrink) continue;
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
                    layout_child.min_size = switch (self.options.direction) {
                        .horiz => .{ .width = measured, .height = null },
                        .vert => .{ .width = null, .height = measured },
                    };
                    layout_child.max_size = layout_child.min_size;
                }
            }

            const grow_target: ?usize = switch (self.options.direction) {
                .horiz => if (constraint.max_size.width orelse constraint.min_size.width) |target| target -| border_size * 2 else null,
                .vert => if (constraint.max_size.height orelse constraint.min_size.height) |target| target -| border_size * 2 else null,
            };

            for (layout_order.items, 0..) |layout_child, sorted_child_index| {
                var child = &self.children.values()[layout_child.index];
                child.rect = null;
                child.widget.clearGrid();

                // a hidden child takes no space: leave its grid cleared so the
                // placement loop routes it through the no-grid branch.
                if (child.hidden) continue;

                // skip any children after the first if their min size is too large
                if (sorted_child_index > 0) {
                    if (remaining_width_maybe) |remaining_width| {
                        if (remaining_width <= 0) continue;
                        if (layout_child.min_size.width) |min_width| {
                            if (remaining_width < min_width) continue;
                        }
                    }
                    if (remaining_height_maybe) |remaining_height| {
                        if (remaining_height <= 0) continue;
                        if (layout_child.min_size.height) |min_height| {
                            if (remaining_height < min_height) continue;
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
                var child_min_size = layout_child.min_size;
                if (expected_remaining_width_maybe) |*expected_remaining_width| {
                    const self_min_width = child_min_size.width orelse 0;
                    for (layout_order.items[sorted_child_index + 1 ..]) |next_layout_child| {
                        const next_child = &self.children.values()[next_layout_child.index];
                        if (next_child.hidden) continue;
                        if (next_layout_child.min_size.width) |next_min_width| {
                            if (expected_remaining_width.* >= self_min_width + next_min_width) {
                                expected_remaining_width.* -= next_min_width;
                            }
                        }
                    }
                }
                if (expected_remaining_height_maybe) |*expected_remaining_height| {
                    const self_min_height = child_min_size.height orelse 0;
                    for (layout_order.items[sorted_child_index + 1 ..]) |next_layout_child| {
                        const next_child = &self.children.values()[next_layout_child.index];
                        if (next_child.hidden) continue;
                        if (next_layout_child.min_size.height) |next_min_height| {
                            if (expected_remaining_height.* >= self_min_height + next_min_height) {
                                expected_remaining_height.* -= next_min_height;
                            }
                        }
                    }
                }

                var grow_size: ?usize = null;
                if (child.flex == .grow) {
                    if (grow_target) |target| {
                        const used = switch (self.options.direction) {
                            .horiz => width,
                            .vert => height,
                        };
                        grow_size = (target -| used) / grow_count;
                    }
                    grow_count -= 1;
                }

                // propagate whatever's left of our parent's min-size to the
                // last fixed child. flexible children handle that space above.
                if (sorted_child_index + 1 == layout_order.items.len and child.flex == .none) {
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
                var child_max_width = clampMax(expected_remaining_width_maybe, layout_child.max_size.width);
                var child_max_height = clampMax(expected_remaining_height_maybe, layout_child.max_size.height);

                if (grow_size) |size| switch (self.options.direction) {
                    .horiz => {
                        child_min_size.width = size;
                        child_max_width = size;
                    },
                    .vert => {
                        child_min_size.height = size;
                        child_max_height = size;
                    },
                };

                if (self.options.stretch) {
                    switch (self.options.direction) {
                        .vert => if (child_max_width) |max_w| {
                            if (max_w > (child_min_size.width orelse 0)) child_min_size.width = max_w;
                        },
                        .horiz => if (child_max_height) |max_h| {
                            if (max_h > (child_min_size.height orelse 0)) child_min_size.height = max_h;
                        },
                    }
                }

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

            // widen for the labels, up to the width we're allowed
            if (border_size > 0) {
                const label_min = @max(try wth.displayWidth(self.options.label), try wth.displayWidth(self.options.bottom_label));
                if (label_min > 0) {
                    width = @max(width, label_min + border_size * 2);
                    if (constraint.max_size.width) |max_width| width = @min(width, max_width);
                }
            }

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

            if (self.options.border_style) |border_style| {
                try draw.border(&grid, border_style, self.options.rounded_corners, self.options.label, self.options.bottom_label);
            }

            // set grid
            self.grid = grid;

            // the top-level build is the only one handed its own focus node as
            // the root focus; reaching it here means the whole focusable tree has
            // just been flattened into root_focus. recover focus if this build
            // dropped the widget that held it (e.g. a flex child that no longer
            // fit and had its focus subtree cleared) by re-deriving it down the
            // selected-child chain. a no-op for nested boxes and whenever focus is
            // still live, so callers never have to manage this themselves.
            if (root_focus == self.getFocus()) root_focus.refocus();
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
            border_style: ?draw.BorderStyle,
            rounded_corners: bool = false,
            wrap_kind: WrapKind,
            // optional labels rendered over the top and bottom borders.
            label: []const u8 = "",
            bottom_label: []const u8 = "",
        };

        pub fn init(
            allocator: std.mem.Allocator,
            content: []const u8,
            options: Options,
        ) !TextBox(Widget) {
            const owned_content = try allocator.dupe(u8, content);
            errdefer allocator.free(owned_content);

            var lines = try splitLines(allocator, owned_content);
            errdefer {
                for (lines.items) |line| {
                    allocator.free(line);
                }
                lines.deinit(allocator);
            }

            var box = try Box(Widget).init(allocator, .{ .border_style = options.border_style, .rounded_corners = options.rounded_corners, .direction = .vert, .label = options.label, .bottom_label = options.bottom_label });
            errdefer box.deinit(allocator);
            box.getFocus().kind = .text_box;
            try resetTextChildren(allocator, &box, lines.items);

            return .{
                .box = box,
                .options = options,
                .last_wrap_width = null,
                .content = owned_content,
                .lines = lines,
            };
        }

        pub fn deinit(self: *TextBox(Widget), allocator: std.mem.Allocator) void {
            self.box.deinit(allocator);
            for (self.lines.items) |line| {
                allocator.free(line);
            }
            self.lines.deinit(allocator);
            allocator.free(self.content);
        }

        pub fn setContent(self: *TextBox(Widget), allocator: std.mem.Allocator, content: []const u8) !void {
            if (std.mem.eql(u8, self.content, content)) return;

            const owned_content = try allocator.dupe(u8, content);
            const lines = splitLines(allocator, owned_content) catch |err| {
                allocator.free(owned_content);
                return err;
            };
            for (self.lines.items) |line| allocator.free(line);
            self.lines.deinit(allocator);
            self.lines = lines;
            allocator.free(self.content);
            self.content = owned_content;
            self.last_wrap_width = null;
            try resetTextChildren(allocator, &self.box, self.lines.items);
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
                                var line_w: usize = 0;

                                var utf8 = (try std.unicode.Utf8View.init(self.content)).iterator();
                                while (utf8.nextCodepointSlice()) |char| {
                                    if (std.mem.eql(u8, char, "\n")) {
                                        try self.lines.append(allocator, try line.toOwnedSlice(allocator));
                                        line_w = 0;
                                    } else {
                                        const w = wth.cellWidth(try std.unicode.utf8Decode(char));
                                        // a wide rune that doesn't fit the remaining
                                        // columns wraps early, leaving the last
                                        // column blank
                                        if (line_w > 0 and line_w + w > inner_width) {
                                            try self.lines.append(allocator, try line.toOwnedSlice(allocator));
                                            line_w = 0;
                                        }
                                        try line.appendSlice(allocator, char);
                                        line_w += w;
                                    }

                                    // wrapping is lazy (a full line breaks
                                    // only when another char needs room), so
                                    // a "\n" can't flush an emptied line
                                    if (std.mem.eql(u8, utf8.peek(1), "")) {
                                        try self.lines.append(allocator, try line.toOwnedSlice(allocator));
                                    }
                                }
                            },
                            .word => {
                                var line: std.ArrayList(u8) = .empty;
                                errdefer line.deinit(allocator);
                                var line_w: usize = 0;

                                var word: std.ArrayList(u8) = .empty;
                                defer word.deinit(allocator);
                                var word_w: usize = 0;

                                var utf8 = (try std.unicode.Utf8View.init(self.content)).iterator();
                                while (utf8.nextCodepointSlice()) |cp| {
                                    const is_newline = std.mem.eql(u8, cp, "\n");
                                    const is_space = std.mem.eql(u8, cp, " ") or std.mem.eql(u8, cp, "\t");

                                    if (is_newline or is_space) {
                                        try flushPendingWord(allocator, &self.lines, &line, &line_w, &word, &word_w, inner_width);
                                    }

                                    if (is_newline) {
                                        try self.lines.append(allocator, try line.toOwnedSlice(allocator));
                                        line_w = 0;
                                    } else if (is_space) {
                                        // collapse spaces at the start of a line; otherwise keep
                                        // the separator and drop trailing spaces past the edge.
                                        if (line_w > 0 and line_w < inner_width) {
                                            try line.appendSlice(allocator, cp);
                                            line_w += 1;
                                        }
                                    } else {
                                        try word.appendSlice(allocator, cp);
                                        word_w += wth.cellWidth(try std.unicode.utf8Decode(cp));
                                    }

                                    if (std.mem.eql(u8, utf8.peek(1), "")) {
                                        try flushPendingWord(allocator, &self.lines, &line, &line_w, &word, &word_w, inner_width);
                                        try self.lines.append(allocator, try line.toOwnedSlice(allocator));
                                        line_w = 0;
                                    }
                                }
                            },
                        }

                        // refresh the inner box's children in-place
                        try resetTextChildren(allocator, &self.box, self.lines.items);
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
            self.box.options.label = self.options.label;
            self.box.options.bottom_label = self.options.bottom_label;
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

        // replace the inner box's children with one Text row per line
        fn resetTextChildren(allocator: std.mem.Allocator, box: *Box(Widget), lines: []const []const u8) !void {
            for (box.children.values()) |*child| child.widget.deinit(allocator);
            box.children.clearAndFree(allocator);
            for (lines) |line| {
                var text = try Text(Widget).init(allocator, line);
                errdefer text.deinit(allocator);
                try box.children.put(allocator, text.getFocus().id, .{ .widget = .{ .text = text }, .rect = null, .min_size = null });
            }
        }

        fn splitLines(allocator: std.mem.Allocator, content: []const u8) !std.ArrayList([]const u8) {
            var lines: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (lines.items) |line| allocator.free(line);
                lines.deinit(allocator);
            }
            var line: std.ArrayList(u8) = .empty;
            errdefer line.deinit(allocator);

            var utf8 = (try std.unicode.Utf8View.init(content)).iterator();
            while (utf8.nextCodepointSlice()) |char| {
                if (std.mem.eql(u8, char, "\n")) {
                    const owned = try line.toOwnedSlice(allocator);
                    lines.append(allocator, owned) catch |err| {
                        allocator.free(owned);
                        return err;
                    };
                } else {
                    try line.appendSlice(allocator, char);
                }
            }
            const owned = try line.toOwnedSlice(allocator);
            lines.append(allocator, owned) catch |err| {
                allocator.free(owned);
                return err;
            };
            return lines;
        }

        fn flushPendingWord(
            allocator: std.mem.Allocator,
            lines: *std.ArrayList([]const u8),
            line: *std.ArrayList(u8),
            line_w: *usize,
            word: *std.ArrayList(u8),
            word_w: *usize,
            inner_width: usize,
        ) !void {
            if (word_w.* == 0) return;

            if (line_w.* + word_w.* <= inner_width) {
                try line.appendSlice(allocator, word.items);
                line_w.* += word_w.*;
            } else if (word_w.* <= inner_width) {
                // wrap to a fresh line so the word stays intact
                if (line_w.* > 0) {
                    try lines.append(allocator, try line.toOwnedSlice(allocator));
                    line_w.* = 0;
                }
                try line.appendSlice(allocator, word.items);
                line_w.* = word_w.*;
            } else {
                // word is longer than a whole line — fall back to char-wrap so
                // it at least renders rather than disappearing past the edge.
                if (line_w.* > 0) {
                    try lines.append(allocator, try line.toOwnedSlice(allocator));
                    line_w.* = 0;
                }
                var w_utf8 = (try std.unicode.Utf8View.init(word.items)).iterator();
                while (w_utf8.nextCodepointSlice()) |c| {
                    const w = wth.cellWidth(try std.unicode.utf8Decode(c));
                    if (line_w.* > 0 and line_w.* + w > inner_width) {
                        try lines.append(allocator, try line.toOwnedSlice(allocator));
                        line_w.* = 0;
                    }
                    try line.appendSlice(allocator, c);
                    line_w.* += w;
                }
            }

            word.clearRetainingCapacity();
            word_w.* = 0;
        }
    };
}

pub fn TextInput(comptime Widget: type) type {
    return struct {
        focus: *Focus,
        grid: ?Grid,
        content: std.ArrayList(u21),
        cursor: usize,
        scroll_offset: usize,
        options: Options,
        // multiline state: content index where each visual row starts, the
        // first displayed row, and the wrap width of the last build (so input
        // can recompute the rows between builds)
        row_starts: std.ArrayList(usize),
        row_offset: usize,
        last_wrap_width: ?usize,

        pub const Options = struct {
            border_style: ?draw.BorderStyle = .single_dashed,
            rounded_corners: bool = false,
            // visible width in codepoints, excluding the border (null = fill
            // the available width)
            visible_width: ?usize = 20,
            // when true, every character is rendered as a bullet so the
            // actual content isn't visible on screen
            password: bool = false,
            // optional labels rendered over the top and bottom borders. when
            // empty, that border is drawn unchanged.
            label: []const u8 = "",
            bottom_label: []const u8 = "",
            // optional form-field name; the web renderer emits it as the
            // HTML `name` attribute so the value is submitted with that key.
            name: []const u8 = "",
            // prevent changes to the content while retaining cursor navigation
            read_only: bool = false,
            // when false, the content (and cursor) aren't drawn into the grid
            render_content: bool = true,
            // edit multiple lines: enter inserts a newline, long lines soft
            // word-wrap, and the height grows with the content
            multiline: bool = false,
            // content rows shown, fixed: shorter content leaves blank rows,
            // longer content scrolls (null = grow with the content, bounded
            // only by the constraint)
            visible_height: ?usize = null,
            // options for multiline scrolling; only fill, show_bar, and
            // web_native are honored
            scroll: Scroll(Widget).Options = .{},
        };

        pub fn init(allocator: std.mem.Allocator, options: Options) !TextInput(Widget) {
            return .{
                .focus = try Focus.create(allocator, if (options.password)
                    .text_input_password
                else if (options.multiline)
                    .text_area
                else
                    .text_input),
                .grid = null,
                .content = .empty,
                .cursor = 0,
                .scroll_offset = 0,
                .options = options,
                .row_starts = .empty,
                .row_offset = 0,
                .last_wrap_width = null,
            };
        }

        pub fn deinit(self: *TextInput(Widget), allocator: std.mem.Allocator) void {
            self.focus.destroy(allocator);
            self.clearGrid();
            self.content.deinit(allocator);
            self.row_starts.deinit(allocator);
        }

        // replace all typed content at once. cursor lands at the end so
        // subsequent edits (or rendering) treat it as the new state.
        pub fn setContent(self: *TextInput(Widget), allocator: std.mem.Allocator, bytes: []const u8) !void {
            var content: std.ArrayList(u21) = .empty;
            errdefer content.deinit(allocator);
            var utf8 = (try std.unicode.Utf8View.init(bytes)).iterator();
            while (utf8.nextCodepoint()) |cp| {
                try content.append(allocator, cp);
            }

            self.content.deinit(allocator);
            self.content = content;
            self.cursor = self.content.items.len;
            self.scroll_offset = 0;
            self.row_offset = 0;
        }

        pub fn clear(self: *TextInput(Widget), allocator: std.mem.Allocator) void {
            self.content.clearAndFree(allocator);
            self.cursor = 0;
            self.scroll_offset = 0;
            self.row_offset = 0;
        }

        // encode the stored codepoints into a single owned utf-8 buffer
        pub fn text(self: *const TextInput(Widget), allocator: std.mem.Allocator) ![]u8 {
            var text_buffer: std.ArrayList(u8) = .empty;
            errdefer text_buffer.deinit(allocator);
            for (self.content.items) |cp| {
                var encoded: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(cp, &encoded);
                try text_buffer.appendSlice(allocator, encoded[0..len]);
            }
            return text_buffer.toOwnedSlice(allocator);
        }

        // display columns the codepoint at content index i occupies on
        // screen. password mode renders a bullet regardless of the hidden
        // codepoint, so everything is one column there.
        fn contentCellWidth(self: *const TextInput(Widget), i: usize) usize {
            if (self.options.password) return 1;
            return wth.cellWidth(self.content.items[i]);
        }

        // display columns of the content range [start, end)
        fn columnsBetween(self: *const TextInput(Widget), start: usize, end: usize) usize {
            var total: usize = 0;
            for (start..end) |i| total += self.contentCellWidth(i);
            return total;
        }

        // rebuild row_starts: the content index where each visual row begins.
        // rows break on "\n" (kept in the row, stripped for display) and soft
        // word-wrap at wrap_width display columns, so every index lands in
        // exactly one row.
        fn computeRowStarts(self: *TextInput(Widget), allocator: std.mem.Allocator, wrap_width: usize) !void {
            self.row_starts.clearRetainingCapacity();
            try self.row_starts.append(allocator, 0);
            var col: usize = 0;
            var last_space: ?usize = null;
            for (self.content.items, 0..) |cp, i| {
                if (cp == '\n') {
                    try self.row_starts.append(allocator, i + 1);
                    col = 0;
                    last_space = null;
                    continue;
                }
                const w = self.contentCellWidth(i);
                // an overflowing space stays put as trailing whitespace
                // instead of opening a row of its own; the next word breaks
                const is_space = cp == ' ';
                if (!is_space and col > 0 and col + w > wrap_width) {
                    // break after the row's last space if it has one,
                    // otherwise char-wrap
                    const start = if (last_space) |space| space + 1 else i;
                    try self.row_starts.append(allocator, start);
                    col = self.columnsBetween(start, i);
                    last_space = null;
                }
                if (is_space) last_space = i;
                col += w;
            }
        }

        // the cursor's visual row and its codepoint offset within that row.
        // offset is an index distance, not a screen column — columnsBetween
        // converts it when drawing.
        fn cursorRowCol(self: *const TextInput(Widget)) struct { row: usize, offset: usize } {
            var row = self.row_starts.items.len - 1;
            while (self.row_starts.items[row] > self.cursor) row -= 1;
            return .{ .row = row, .offset = self.cursor - self.row_starts.items[row] };
        }

        // the largest cursor index on the row: its "\n" (or last soft-wrapped
        // char) when another row follows, else the end of the content
        fn rowMaxIndex(self: *const TextInput(Widget), row: usize) usize {
            return if (row + 1 < self.row_starts.items.len)
                self.row_starts.items[row + 1] - 1
            else
                self.content.items.len;
        }

        // for parents routing arrow keys: whether up/down has a row to move
        // to, or should move focus out of the input instead
        pub fn cursorOnFirstRow(self: *TextInput(Widget), allocator: std.mem.Allocator) !bool {
            if (!self.options.multiline) return true;
            const wrap_width = self.last_wrap_width orelse return true;
            try self.computeRowStarts(allocator, wrap_width);
            return self.cursorRowCol().row == 0;
        }

        pub fn cursorOnLastRow(self: *TextInput(Widget), allocator: std.mem.Allocator) !bool {
            if (!self.options.multiline) return true;
            const wrap_width = self.last_wrap_width orelse return true;
            try self.computeRowStarts(allocator, wrap_width);
            return self.cursorRowCol().row == self.row_starts.items.len - 1;
        }

        pub fn build(self: *TextInput(Widget), allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();

            const effective_border: ?draw.BorderStyle = if (self.options.border_style) |base| switch (base) {
                .hidden => .hidden,
                else => if (root_focus.grandchild_id == self.focus.id) .double_dashed else .single_dashed,
            } else null;

            const border_size: usize = if (effective_border) |_| 1 else 0;
            const height: usize = 1 + border_size * 2;

            // width is fixed at the option's visible_width (longer content
            // scrolls horizontally inside it), or fills the constraint. an
            // unbounded fill has no width to take, so it renders nothing.
            const width: usize = blk: {
                const visible_width = self.options.visible_width orelse break :blk constraint.max_size.width orelse return;
                // widen for the labels so they stay visible between the corners
                const label_min = if (border_size > 0)
                    @max(try wth.displayWidth(self.options.label), try wth.displayWidth(self.options.bottom_label))
                else
                    0;
                const desired_width = @max(visible_width, label_min) + border_size * 2;
                break :blk if (constraint.max_size.width) |max_width|
                    @min(desired_width, max_width)
                else
                    desired_width;
            };

            if (width <= border_size * 2) return;

            const inner_width = width - border_size * 2;

            if (self.options.multiline) {
                try self.buildMultiline(allocator, constraint, root_focus, effective_border, width, inner_width);
                return;
            }

            // keep the cursor inside the visible window, measured in display
            // columns (a wide rune fills two)
            if (self.cursor < self.scroll_offset) {
                self.scroll_offset = self.cursor;
            } else {
                // the cursor's own cell: a content rune, or one trailing
                // space column when it sits past the end. the window can
                // land at most on the cursor itself — a wide cursor rune in
                // a one-column window just doesn't render.
                const cursor_w: usize = if (self.cursor < self.content.items.len) self.contentCellWidth(self.cursor) else 1;
                while (self.scroll_offset < self.cursor and
                    self.columnsBetween(self.scroll_offset, self.cursor) + cursor_w > inner_width)
                {
                    self.scroll_offset += 1;
                }
            }

            var grid = try Grid.init(allocator, .{ .width = width, .height = height });
            errdefer grid.deinit();

            const has_focus = root_focus.grandchild_id == self.focus.id;

            // text + cursor (skipped when an external overlay owns the display)
            if (self.options.render_content) {
                var col: usize = 0;
                var content_index = self.scroll_offset;
                const cell_y = border_size;
                while (col < inner_width) {
                    const cell_x = col + border_size;
                    if (content_index < self.content.items.len) {
                        const w = self.contentCellWidth(content_index);
                        // a wide rune that doesn't fit the last column is
                        // left undrawn
                        if (col + w > inner_width) break;
                        try grid.setRune(cell_x, cell_y, if (self.options.password) '•' else self.content.items[content_index]);
                        if (content_index == self.cursor and has_focus) {
                            (try grid.cell(cell_x, cell_y)).style.inverted = true;
                        }
                        col += w;
                        content_index += 1;
                    } else {
                        if (self.cursor == content_index and has_focus) {
                            // cursor sits past the last char — paint a space underneath
                            try grid.setRune(cell_x, cell_y, ' ');
                            (try grid.cell(cell_x, cell_y)).style.inverted = true;
                        }
                        break;
                    }
                }
            }

            // border
            if (effective_border) |border_style| {
                try draw.border(&grid, border_style, self.options.rounded_corners, self.options.label, self.options.bottom_label);
            }

            self.grid = grid;
        }

        fn viewportRows(self: *const TextInput(Widget), rows: usize, avail_rows: ?usize) usize {
            if (self.options.scroll.fill) {
                if (avail_rows) |available| return available;
            }
            const wanted = if (self.options.visible_height) |v| @max(1, v) else rows;
            return @min(wanted, avail_rows orelse wanted);
        }

        fn buildMultiline(self: *TextInput(Widget), allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus, effective_border: ?draw.BorderStyle, width: usize, inner_width: usize) !void {
            const border_size: usize = if (effective_border) |_| 1 else 0;

            // rows the constraint allows; null = unbounded. A bounded height
            // that cannot fit the borders and one content row renders nothing,
            // matching the other widgets' zero-budget behavior.
            const avail_rows: ?usize = if (constraint.max_size.height) |max_height|
                max_height -| border_size * 2
            else
                null;
            if (avail_rows) |available| {
                if (available == 0) return;
            }

            // one column is reserved so the caret can sit past a full row;
            // when the rows overflow, another goes to the scroll bar (which
            // only adds rows, so the bar decision can't flip back)
            var bar: usize = 0;
            var wrap_width = @max(1, inner_width -| 1);
            try self.computeRowStarts(allocator, wrap_width);
            var rows = self.row_starts.items.len;
            var vp_h = self.viewportRows(rows, avail_rows);
            if (rows > vp_h and self.options.scroll.show_bar and !self.options.scroll.web_native) {
                bar = 1;
                wrap_width = @max(1, inner_width -| 2);
                try self.computeRowStarts(allocator, wrap_width);
                rows = self.row_starts.items.len;
                vp_h = self.viewportRows(rows, avail_rows);
            }
            self.last_wrap_width = wrap_width;

            // keep the cursor's row inside the visible window
            const rc = self.cursorRowCol();
            if (rc.row < self.row_offset) {
                self.row_offset = rc.row;
            } else if (rc.row >= self.row_offset + vp_h) {
                self.row_offset = rc.row + 1 - vp_h;
            }
            self.row_offset = @min(self.row_offset, rows -| vp_h);

            var grid = try Grid.init(allocator, .{ .width = width, .height = vp_h + border_size * 2 });
            errdefer grid.deinit();

            const has_focus = root_focus.grandchild_id == self.focus.id;

            // rows + cursor (skipped when an external overlay owns the display)
            if (self.options.render_content) {
                const content_width = inner_width - bar;
                for (0..vp_h) |view_row| {
                    const row = self.row_offset + view_row;
                    if (row >= rows) break;
                    const start = self.row_starts.items[row];
                    var end = if (row + 1 < rows) self.row_starts.items[row + 1] else self.content.items.len;
                    if (end > start and self.content.items[end - 1] == '\n') end -= 1;
                    var col: usize = 0;
                    for (start..end) |i| {
                        const w = self.contentCellWidth(i);
                        if (col + w > content_width) break;
                        try grid.setRune(border_size + col, border_size + view_row, if (self.options.password) '•' else self.content.items[i]);
                        col += w;
                    }
                }

                if (has_focus) {
                    // the cursor's screen column within its row (its offset
                    // counts codepoints, so convert to display columns)
                    const cur_col = self.columnsBetween(self.row_starts.items[rc.row], self.cursor);
                    if (cur_col < inner_width - bar) {
                        const view_row = rc.row - self.row_offset;
                        const cursor_cell = try grid.cell(border_size + cur_col, border_size + view_row);
                        if (cursor_cell.rune == null and !cursor_cell.continuation) {
                            try grid.setRune(border_size + cur_col, border_size + view_row, ' ');
                        }
                        cursor_cell.style.inverted = true;
                    }
                }

                if (bar == 1) {
                    try draw.scrollBarVert(&grid, border_size + inner_width - 1, border_size, vp_h, rows, vp_h, @intCast(self.row_offset));
                }
            }

            if (effective_border) |border_style| {
                try draw.border(&grid, border_style, self.options.rounded_corners, self.options.label, self.options.bottom_label);
            }

            self.grid = grid;
        }

        pub fn input(self: *TextInput(Widget), allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
            _ = root_focus;
            if (self.options.read_only) switch (key) {
                .enter, .delete, .backspace, .codepoint => return,
                else => {},
            };
            if (self.options.multiline) {
                switch (key) {
                    .enter => {
                        try self.content.insert(allocator, self.cursor, '\n');
                        self.cursor += 1;
                        return;
                    },
                    .arrow_up, .arrow_down, .home, .end => {
                        const wrap_width = self.last_wrap_width orelse return;
                        try self.computeRowStarts(allocator, wrap_width);
                        const rc = self.cursorRowCol();
                        switch (key) {
                            .arrow_up => if (rc.row > 0) {
                                self.cursor = @min(self.row_starts.items[rc.row - 1] + rc.offset, self.rowMaxIndex(rc.row - 1));
                            },
                            .arrow_down => if (rc.row + 1 < self.row_starts.items.len) {
                                self.cursor = @min(self.row_starts.items[rc.row + 1] + rc.offset, self.rowMaxIndex(rc.row + 1));
                            },
                            .home => self.cursor = self.row_starts.items[rc.row],
                            .end => self.cursor = self.rowMaxIndex(rc.row),
                            else => unreachable,
                        }
                        return;
                    },
                    else => {},
                }
            }
            switch (key) {
                .arrow_left => self.cursor -|= 1,
                .arrow_right => if (self.cursor < self.content.items.len) {
                    self.cursor += 1;
                },
                .home => self.cursor = 0,
                .end => self.cursor = self.content.items.len,
                .delete => if (self.cursor < self.content.items.len) {
                    _ = self.content.orderedRemove(self.cursor);
                },
                .backspace => if (self.cursor > 0) {
                    _ = self.content.orderedRemove(self.cursor - 1);
                    self.cursor -= 1;
                },
                .codepoint => |cp| {
                    // ignore control characters; only printable text is inserted
                    if (cp < 0x20) return;
                    try self.content.insert(allocator, self.cursor, cp);
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

        pub const Options = struct {
            direction: ScrollDirection = .vert,
            show_bar: bool = true,
            // when true, expose the full unclipped content (and skip the text
            // scrollbar and focus-rect clipping) so a web renderer can place the
            // content in a natively-scrollable element
            web_native: bool = false,
            // when true, the grid fills its bounded viewport (content drawn at the
            // top-left, any scroll bar pinned to the far edge) instead of shrinking
            // to the content. lets a bordered/parent layout keep the bar at its
            // edge even when the content is smaller than the viewport.
            fill: bool = false,
        };

        // subtract a scroll bar's reserved column/row from an optional size
        // constraint, keeping at least one cell. a null (unbounded) size stays null.
        fn subReserve(size: ?usize, reserve: usize) ?usize {
            return if (size) |s| (if (s > reserve) s - reserve else 1) else null;
        }

        fn clampOffsets(self: *Scroll(Widget), content: layout.Size, view_w: usize, view_h: usize) void {
            const max_x: isize = if (content.width > view_w) @intCast(content.width - view_w) else 0;
            const max_y: isize = if (content.height > view_h) @intCast(content.height - view_h) else 0;
            self.x = std.math.clamp(self.x, 0, max_x);
            self.y = std.math.clamp(self.y, 0, max_y);
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
            self.clearGrid();
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
                    const content_w = @max(1, if (self.options.fill) avail_w else @min(child_grid.size.width, avail_w));
                    const content_h = @max(1, if (self.options.fill) avail_h else @min(child_grid.size.height, avail_h));
                    self.clampOffsets(child_grid.size, content_w, content_h);
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
                const content_w = @max(1, if (self.options.fill) avail_w else @min(child_grid.size.width, avail_w));
                const content_h = @max(1, if (self.options.fill) avail_h else @min(child_grid.size.height, avail_h));
                self.clampOffsets(child_grid.size, content_w, content_h);

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
                        try draw.scrollBarVert(&full, content_w, 0, content_h, child_grid.size.height, content_h, self.y);
                    }
                    if (reserve_h == 1) {
                        try draw.scrollBarHoriz(&full, 0, content_h, content_w, child_grid.size.width, content_w, self.x);
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

        // keep the scroll offsets within the content, using the last build's
        // grids. the bar's reserved column/row isn't part of the content
        // viewport, so exclude it (as scrollToRect does) or the last
        // column/row stays unreachable.
        pub fn clampToContent(self: *Scroll(Widget)) void {
            const vp = self.grid orelse return;
            const content = self.child.getGrid() orelse return;
            const view_w = vp.size.width - self.bar_w;
            const view_h = vp.size.height - self.bar_h;
            self.clampOffsets(content.size, view_w, view_h);
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
