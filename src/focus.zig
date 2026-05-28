const std = @import("std");
const layout = @import("./layout.zig");

var next_id: usize = 0;

pub const FocusKind = union(enum) {
    container,
    text,
    text_box,
    text_input,
    text_input_password,
    custom: []const u8,
};

const Child = struct {
    parent_id: usize,
    focus: *Focus,
    rect: layout.URect,
};

pub const Focus = struct {
    id: usize,
    kind: FocusKind,
    child_id: ?usize,
    grandchild_id: ?usize,
    focusable: bool,
    allocator: std.mem.Allocator,
    children: std.AutoArrayHashMapUnmanaged(usize, Child),

    pub fn init(allocator: std.mem.Allocator, kind: FocusKind) Focus {
        const id = next_id;
        next_id += 1;
        return .{
            .id = id,
            .kind = kind,
            .child_id = null,
            .grandchild_id = null,
            .focusable = false,
            .allocator = allocator,
            .children = .empty,
        };
    }

    pub fn deinit(self: *Focus) void {
        self.children.deinit(self.allocator);
    }

    pub fn addChild(self: *Focus, child: *Focus, size: layout.Size, target_x: usize, target_y: usize) !void {
        try self.children.put(self.allocator, child.id, .{
            .parent_id = self.id,
            .focus = child,
            .rect = .{ .x = target_x, .y = target_y, .size = size },
        });
        var iter = child.children.iterator();
        while (iter.next()) |entry| {
            const grandchild = entry.value_ptr.*;
            try self.children.put(self.allocator, entry.key_ptr.*, .{
                .parent_id = grandchild.parent_id,
                .focus = grandchild.focus,
                .rect = .{ .x = target_x + grandchild.rect.x, .y = target_y + grandchild.rect.y, .size = grandchild.rect.size },
            });
        }
    }

    pub fn clear(self: *Focus) void {
        self.children.clearRetainingCapacity();
    }

    pub fn setFocus(self: *Focus, grandchild_id: usize) !void {
        var id = grandchild_id;
        // find the nearest child to grandchild_id that is focusable
        while (self.children.get(id)) |child| {
            if (child.focus.focusable) {
                break;
            } else if (child.focus.child_id) |next_child_id| {
                // stop descending if the next id isn't in our focus tree
                // (e.g. the target child wasn't laid out this build, or its
                // descendants were just replaced and haven't been re-added).
                // without this guard we'd commit to a dead-end id and the
                // walk-up below would silently no-op, leaving ancestor
                // child_id values pointing at the previous focus.
                if (!self.children.contains(next_child_id)) break;
                id = next_child_id;
            } else {
                return;
            }
        }
        // set the child_id of all parents so the id is focused
        self.grandchild_id = id;
        while (self.children.get(id)) |child| {
            if (self.children.get(child.parent_id)) |*parent| {
                parent.focus.child_id = id;
            } else if (child.parent_id == self.id) {
                self.child_id = id;
            }
            id = child.parent_id;
        }
    }
};
