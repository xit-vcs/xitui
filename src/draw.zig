//! grid painting helpers: borders, border labels, and scroll bar parts.

const std = @import("std");
const Grid = @import("./grid.zig").Grid;
const wth = @import("./width.zig");

pub const BorderStyle = enum {
    hidden,
    single,
    double,
    single_dashed,
    double_dashed,
};

// overlay a label on the border row at `y`, truncating at the far corner.
pub fn label(grid: *Grid, y: usize, text: []const u8) !void {
    if (text.len == 0 or grid.size.width <= 2) return;
    var label_iter = (try std.unicode.Utf8View.init(text)).iterator();
    var x: usize = 1;
    while (label_iter.nextCodepoint()) |ch| {
        const w = wth.cellWidth(ch);
        if (x + w > grid.size.width - 1) break;
        try grid.setRune(x, y, ch);
        x += w;
    }
}

// draw a border (and its labels) around the outermost cells of the grid.
pub fn border(grid: *Grid, border_style: BorderStyle, rounded_corners: bool, top_label: []const u8, bottom_label: []const u8) !void {
    const dashed = border_style == .single_dashed or border_style == .double_dashed;
    const horiz_line: u21 = switch (border_style) {
        .hidden => ' ',
        .single, .single_dashed => '─',
        .double, .double_dashed => '═',
    };
    const vert_line: u21 = switch (border_style) {
        .hidden => ' ',
        .single, .single_dashed => '│',
        .double, .double_dashed => '║',
    };
    const top_left: u21 = switch (border_style) {
        .hidden => ' ',
        .single, .single_dashed => if (rounded_corners) '╭' else '┌',
        .double, .double_dashed => if (rounded_corners) '╭' else '╔',
    };
    const top_right: u21 = switch (border_style) {
        .hidden => ' ',
        .single, .single_dashed => if (rounded_corners) '╮' else '┐',
        .double, .double_dashed => if (rounded_corners) '╮' else '╗',
    };
    const bottom_left: u21 = switch (border_style) {
        .hidden => ' ',
        .single, .single_dashed => if (rounded_corners) '╰' else '└',
        .double, .double_dashed => if (rounded_corners) '╰' else '╚',
    };
    const bottom_right: u21 = switch (border_style) {
        .hidden => ' ',
        .single, .single_dashed => if (rounded_corners) '╯' else '┘',
        .double, .double_dashed => if (rounded_corners) '╯' else '╝',
    };
    for (1..grid.size.width - 1) |x| {
        if (dashed and x % 2 == 1) continue;
        try grid.setRune(x, 0, horiz_line);
        try grid.setRune(x, grid.size.height - 1, horiz_line);
    }
    for (1..grid.size.height - 1) |y| {
        if (dashed and y % 2 == 0) continue;
        try grid.setRune(0, y, vert_line);
        try grid.setRune(grid.size.width - 1, y, vert_line);
    }
    try grid.setRune(0, 0, top_left);
    try grid.setRune(grid.size.width - 1, 0, top_right);
    try grid.setRune(0, grid.size.height - 1, bottom_left);
    try grid.setRune(grid.size.width - 1, grid.size.height - 1, bottom_right);

    try label(grid, 0, top_label);
    try label(grid, grid.size.height - 1, bottom_label);
}

// the solid run that represents the visible portion of the content.
const thumb_rune: u21 = '█';
// the lighter run drawn behind the thumb for the rest of the bar.
const track_rune: u21 = '░';

// the thumb's length is the track scaled by the visible fraction of the
// content, its position the scroll offset scaled into the leftover track;
// when everything fits, it fills the whole track.
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

// paint a vertical scroll bar down column `x`, rows [y, y + track_len).
pub fn scrollBarVert(grid: *Grid, x: usize, y: usize, track_len: usize, content_total: usize, viewport: usize, offset: isize) !void {
    const thumb = scrollBarThumb(track_len, content_total, viewport, offset);
    for (0..track_len) |i| {
        try grid.setRune(x, y + i, if (i >= thumb.start and i < thumb.start + thumb.len) thumb_rune else track_rune);
    }
}

// paint a horizontal scroll bar along row `y`, columns [x, x + track_len).
pub fn scrollBarHoriz(grid: *Grid, x: usize, y: usize, track_len: usize, content_total: usize, viewport: usize, offset: isize) !void {
    const thumb = scrollBarThumb(track_len, content_total, viewport, offset);
    for (0..track_len) |i| {
        try grid.setRune(x + i, y, if (i >= thumb.start and i < thumb.start + thumb.len) thumb_rune else track_rune);
    }
}
