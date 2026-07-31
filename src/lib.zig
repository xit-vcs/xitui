pub const draw = @import("./draw.zig");
pub const focus = @import("./focus.zig");
pub const grid = @import("./grid.zig");
pub const input = @import("./input.zig");
pub const layout = @import("./layout.zig");
pub const ndslice = @import("./ndslice.zig");
pub const terminal = @import("./terminal.zig");
pub const width = @import("./width.zig");
pub const stream_terminal = @import("./stream_terminal.zig");
pub const widget = @import("./widget.zig");

// make `zig build test` collect the tests living inside these files
test {
    @import("std").testing.refAllDecls(@This());
}
