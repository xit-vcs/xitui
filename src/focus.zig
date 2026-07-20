const std = @import("std");
const layout = @import("./layout.zig");
const grid = @import("./grid.zig");
const widget = @import("./widget.zig");

var next_id: usize = 0;

pub const FocusKind = union(enum) {
    container,
    text,
    text_box,
    text_input,
    text_input_password,
    text_area,
    custom: []const u8,
};

const Child = struct {
    parent_id: usize,
    focus: *Focus,
    rect: layout.URect,
};

pub const ScrollInfo = struct {
    content: grid.Grid,
    offset_x: isize,
    offset_y: isize,
    direction: widget.ScrollDirection,
};

pub const Focus = struct {
    id: usize,
    kind: FocusKind,
    child_id: ?usize,
    grandchild_id: ?usize,
    focusable: bool,
    children: std.AutoArrayHashMapUnmanaged(usize, Child),
    scroll: ?ScrollInfo,
    // owner-bumped when this node's content is replaced (not merely restyled).
    // persists across builds (unlike `scroll`, which is rebuilt each frame), so a
    // web renderer can reset the native scroll position only on real changes.
    version: u64,

    fn init(kind: FocusKind) Focus {
        const id = next_id;
        next_id += 1;
        return .{
            .id = id,
            .kind = kind,
            .child_id = null,
            .grandchild_id = null,
            .focusable = false,
            .children = .empty,
            .scroll = null,
            .version = 0,
        };
    }

    fn deinit(self: *Focus, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
    }

    pub fn create(allocator: std.mem.Allocator, kind: FocusKind) !*Focus {
        const self = try allocator.create(Focus);
        self.* = Focus.init(kind);
        return self;
    }

    pub fn destroy(self: *Focus, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn addChild(self: *Focus, allocator: std.mem.Allocator, child: *Focus, size: layout.Size, target_x: usize, target_y: usize) !void {
        try self.children.put(allocator, child.id, .{
            .parent_id = self.id,
            .focus = child,
            .rect = .{ .x = target_x, .y = target_y, .size = size },
        });
        var iter = child.children.iterator();
        while (iter.next()) |entry| {
            const grandchild = entry.value_ptr.*;
            try self.children.put(allocator, entry.key_ptr.*, .{
                .parent_id = grandchild.parent_id,
                .focus = grandchild.focus,
                .rect = .{ .x = target_x + grandchild.rect.x, .y = target_y + grandchild.rect.y, .size = grandchild.rect.size },
            });
        }
    }

    pub fn clear(self: *Focus) void {
        self.children.clearRetainingCapacity();
    }

    pub fn setFocus(self: *Focus, grandchild_id: usize) void {
        var id = grandchild_id;
        // descend toward the nearest focusable along the selected-child chain
        while (self.children.get(id)) |child| {
            if (child.focus.focusable) break;
            const next_child_id = child.focus.child_id orelse break;
            // the selected child exists but wasn't laid out this build — a flex
            // child a Box dropped for lack of room, whose focus subtree was
            // cleared. stop here and select this subtree anyway (below) so the
            // next build lays it out; the post-build recovery then lands focus
            // inside it. callers can therefore always just setFocus the thing
            // they want, laid out or not.
            if (!self.children.contains(next_child_id)) break;
            id = next_child_id;
        }

        const target = self.children.get(id) orelse return;
        // a node whose selected child was dropped is worth selecting (it lays out
        // next build); a container that simply has nothing focusable under it
        // (e.g. an empty list) is not — leave focus untouched rather than
        // stranding it somewhere that can't take input.
        const has_dropped_child = if (target.focus.child_id) |c| !self.children.contains(c) else false;
        if (!target.focus.focusable and !has_dropped_child) return;

        // land the cursor only on a focusable target; for a dropped subtree leave
        // grandchild_id where it is and let the post-build recovery move it once
        // the subtree is laid out.
        if (target.focus.focusable) self.grandchild_id = id;

        // select `id` up the chain so every ancestor (and any too-narrow Box)
        // builds toward it next time
        while (self.children.get(id)) |child| {
            if (self.children.get(child.parent_id)) |*parent| {
                parent.focus.child_id = id;
            } else if (child.parent_id == self.id) {
                self.child_id = id;
            }
            id = child.parent_id;
        }
    }

    // re-derive the focused leaf by descending the child_id chain from this node,
    // following each box's currently-selected child to the nearest focusable.
    // call it once after a full (top-level) build: a flex Box that couldn't fit
    // every child drops the ones it didn't lay out and clears their focus
    // subtrees, which can strand grandchild_id on a widget that no longer exists.
    // because the child_id chain still points at the surviving subtree (and at
    // whichever pane a view re-selected before the build), re-descending lands
    // focus there. it's a no-op when the chain already leads to the live focus.
    pub fn refocus(self: *Focus) void {
        const child_id = self.child_id orelse return;
        self.setFocus(child_id);
    }
};
