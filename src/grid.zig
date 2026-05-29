const std = @import("std");
const layout = @import("./layout.zig");
const NDSlice = @import("./ndslice.zig").NDSlice;

pub const Grid = struct {
    allocator: std.mem.Allocator,
    size: layout.Size,
    cells: Cells,
    buffer: []Grid.Cell,

    pub const Color = struct {
        r: u8,
        g: u8,
        b: u8,

        pub fn eql(self: Color, other: Color) bool {
            return self.r == other.r and self.g == other.g and self.b == other.b;
        }
    };

    pub const Style = struct {
        inverted: bool = false,
        // truecolor foreground/background. null means "leave the terminal
        // default", which is how transparency is expressed: a cell with no bg
        // lets whatever is behind it (the terminal background) show through.
        fg: ?Color = null,
        bg: ?Color = null,

        pub fn eql(self: Style, other: Style) bool {
            if (self.inverted != other.inverted) return false;
            if (!optColorEql(self.fg, other.fg)) return false;
            if (!optColorEql(self.bg, other.bg)) return false;
            return true;
        }

        fn optColorEql(a: ?Color, b: ?Color) bool {
            if (a) |av| {
                return if (b) |bv| av.eql(bv) else false;
            }
            return b == null;
        }
    };

    pub const Cell = struct {
        rune: ?[]const u8,
        style: Style = .{},

        pub fn eql(self: Cell, other: Cell) bool {
            if (!self.style.eql(other.style)) return false;
            if (self.rune) |rune| {
                if (other.rune) |other_rune| {
                    return std.mem.eql(u8, rune, other_rune);
                } else {
                    return false;
                }
            } else {
                if (other.rune) |_| {
                    return false;
                } else {
                    return true;
                }
            }
        }
    };
    pub const Cells = NDSlice(Cell, 2, .row_major);

    pub fn init(allocator: std.mem.Allocator, size: layout.Size) !Grid {
        const buffer = try allocator.alloc(Grid.Cell, size.width * size.height);
        errdefer allocator.free(buffer);
        for (buffer) |*cell| {
            cell.* = .{ .rune = null };
        }
        return .{
            .allocator = allocator,
            .size = size,
            .cells = try Grid.Cells.init(.{ size.height, size.width }, buffer),
            .buffer = buffer,
        };
    }

    pub fn initFromGrid(allocator: std.mem.Allocator, grid: Grid, size: layout.Size, grid_x: isize, grid_y: isize) !Grid {
        const buffer = try allocator.alloc(Grid.Cell, size.width * size.height);
        errdefer allocator.free(buffer);
        for (buffer) |*cell| {
            cell.* = .{ .rune = null };
        }
        const ugrid_x: usize = if (grid_x < 0) 0 else @intCast(grid_x);
        const ugrid_y: usize = if (grid_y < 0) 0 else @intCast(grid_y);
        var cells = try Grid.Cells.init(.{ size.height, size.width }, buffer);
        var dest_y: usize = if (grid_y < 0) @abs(grid_y) else 0;
        for (ugrid_y..ugrid_y + size.height) |source_y| {
            var dest_x: usize = if (grid_x < 0) @abs(grid_x) else 0;
            for (ugrid_x..ugrid_x + size.width) |source_x| {
                if (cells.at(.{ dest_y, dest_x })) |dest_index| {
                    if (grid.cells.at(.{ source_y, source_x })) |source_index| {
                        cells.items[dest_index] = grid.cells.items[source_index];
                    } else |_| {
                        break;
                    }
                } else |_| {
                    break;
                }
                dest_x += 1;
            }
            dest_y += 1;
        }
        return .{
            .allocator = allocator,
            .size = size,
            .cells = cells,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.buffer);
    }

    pub fn drawGrid(self: *Grid, child_grid: Grid, target_x: usize, target_y: usize) !void {
        for (0..child_grid.size.height) |y| {
            for (0..child_grid.size.width) |x| {
                const src = child_grid.cells.items[try child_grid.cells.at(.{ y, x })];
                if (self.cells.at(.{ y + target_y, x + target_x })) |index| {
                    self.cells.items[index] = src;
                } else |_| {
                    break;
                }
            }
        }
    }

    pub fn toString(self: Grid, allocator: std.mem.Allocator) ![]const u8 {
        if (self.size.width == 0 or self.size.height == 0) {
            return error.EmptyGrid;
        }

        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);

        for (0..self.size.height) |y| {
            for (0..self.size.width) |x| {
                if (self.cells.items[try self.cells.at(.{ y, x })].rune) |rune| {
                    for (rune) |byte| {
                        try buffer.append(allocator, byte);
                    }
                } else {
                    try buffer.append(allocator, ' ');
                }
            }
            if (y + 1 < self.size.height) {
                try buffer.append(allocator, '\n');
            }
        }

        return try buffer.toOwnedSlice(allocator);
    }
};

test {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, .{ .width = 10, .height = 10 });
    defer grid.deinit();
    try std.testing.expectEqual(null, grid.cells.items[try grid.cells.at(.{ 0, 0 })].rune);
}
