//! display-width classification for unicode codepoints, so widgets can size
//! and wrap text by the terminal columns it occupies rather than by
//! codepoint count.

const std = @import("std");

const Range = struct { first: u21, last: u21 };

// codepoints with East_Asian_Width `W` (wide) or `F` (fullwidth), derived
// from Unicode 16.0 EastAsianWidth.txt: CJK ideographs, kana, hangul
// syllables, fullwidth forms, and the emoji that terminals render two
// columns wide. sorted for binary search. ambiguous-width (`A`) codepoints
// are deliberately absent — most terminals render them narrow.
const wide_ranges = [_]Range{
    .{ .first = 0x1100, .last = 0x115F }, // hangul jamo (leading consonants)
    .{ .first = 0x231A, .last = 0x231B },
    .{ .first = 0x2329, .last = 0x232A },
    .{ .first = 0x23E9, .last = 0x23EC },
    .{ .first = 0x23F0, .last = 0x23F0 },
    .{ .first = 0x23F3, .last = 0x23F3 },
    .{ .first = 0x25FD, .last = 0x25FE },
    .{ .first = 0x2614, .last = 0x2615 },
    .{ .first = 0x2648, .last = 0x2653 },
    .{ .first = 0x267F, .last = 0x267F },
    .{ .first = 0x2693, .last = 0x2693 },
    .{ .first = 0x26A1, .last = 0x26A1 },
    .{ .first = 0x26AA, .last = 0x26AB },
    .{ .first = 0x26BD, .last = 0x26BE },
    .{ .first = 0x26C4, .last = 0x26C5 },
    .{ .first = 0x26CE, .last = 0x26CE },
    .{ .first = 0x26D4, .last = 0x26D4 },
    .{ .first = 0x26EA, .last = 0x26EA },
    .{ .first = 0x26F2, .last = 0x26F3 },
    .{ .first = 0x26F5, .last = 0x26F5 },
    .{ .first = 0x26FA, .last = 0x26FA },
    .{ .first = 0x26FD, .last = 0x26FD },
    .{ .first = 0x2705, .last = 0x2705 },
    .{ .first = 0x270A, .last = 0x270B },
    .{ .first = 0x2728, .last = 0x2728 },
    .{ .first = 0x274C, .last = 0x274C },
    .{ .first = 0x274E, .last = 0x274E },
    .{ .first = 0x2753, .last = 0x2755 },
    .{ .first = 0x2757, .last = 0x2757 },
    .{ .first = 0x2795, .last = 0x2797 },
    .{ .first = 0x27B0, .last = 0x27B0 },
    .{ .first = 0x27BF, .last = 0x27BF },
    .{ .first = 0x2B1B, .last = 0x2B1C },
    .{ .first = 0x2B50, .last = 0x2B50 },
    .{ .first = 0x2B55, .last = 0x2B55 },
    .{ .first = 0x2E80, .last = 0x2E99 }, // cjk radicals
    .{ .first = 0x2E9B, .last = 0x2EF3 },
    .{ .first = 0x2F00, .last = 0x2FD5 }, // kangxi radicals
    .{ .first = 0x2FF0, .last = 0x2FFB }, // ideographic description
    .{ .first = 0x3000, .last = 0x303E }, // cjk symbols and punctuation
    .{ .first = 0x3041, .last = 0x3096 }, // hiragana
    .{ .first = 0x3099, .last = 0x30FF }, // katakana
    .{ .first = 0x3105, .last = 0x312F }, // bopomofo
    .{ .first = 0x3131, .last = 0x318E }, // hangul compatibility jamo
    .{ .first = 0x3190, .last = 0x31E3 },
    .{ .first = 0x31F0, .last = 0x321E },
    .{ .first = 0x3220, .last = 0x3247 },
    .{ .first = 0x3250, .last = 0x4DBF }, // incl. cjk extension A
    .{ .first = 0x4E00, .last = 0xA48C }, // cjk unified ideographs, yi
    .{ .first = 0xA490, .last = 0xA4C6 },
    .{ .first = 0xA960, .last = 0xA97C }, // hangul jamo extended-A
    .{ .first = 0xAC00, .last = 0xD7A3 }, // hangul syllables
    .{ .first = 0xF900, .last = 0xFAFF }, // cjk compatibility ideographs
    .{ .first = 0xFE10, .last = 0xFE19 }, // vertical forms
    .{ .first = 0xFE30, .last = 0xFE52 }, // cjk compatibility forms
    .{ .first = 0xFE54, .last = 0xFE66 },
    .{ .first = 0xFE68, .last = 0xFE6B },
    .{ .first = 0xFF01, .last = 0xFF60 }, // fullwidth forms
    .{ .first = 0xFFE0, .last = 0xFFE6 },
    .{ .first = 0x16FE0, .last = 0x16FE4 },
    .{ .first = 0x16FF0, .last = 0x16FF1 },
    .{ .first = 0x17000, .last = 0x187F7 }, // tangut
    .{ .first = 0x18800, .last = 0x18CD5 },
    .{ .first = 0x18D00, .last = 0x18D08 },
    .{ .first = 0x1AFF0, .last = 0x1AFF3 },
    .{ .first = 0x1AFF5, .last = 0x1AFFB },
    .{ .first = 0x1AFFD, .last = 0x1AFFE },
    .{ .first = 0x1B000, .last = 0x1B122 }, // kana supplement/extended
    .{ .first = 0x1B132, .last = 0x1B132 },
    .{ .first = 0x1B150, .last = 0x1B152 },
    .{ .first = 0x1B155, .last = 0x1B155 },
    .{ .first = 0x1B164, .last = 0x1B167 },
    .{ .first = 0x1B170, .last = 0x1B2FB }, // nushu
    .{ .first = 0x1F004, .last = 0x1F004 },
    .{ .first = 0x1F0CF, .last = 0x1F0CF },
    .{ .first = 0x1F18E, .last = 0x1F18E },
    .{ .first = 0x1F191, .last = 0x1F19A },
    .{ .first = 0x1F200, .last = 0x1F202 },
    .{ .first = 0x1F210, .last = 0x1F23B },
    .{ .first = 0x1F240, .last = 0x1F248 },
    .{ .first = 0x1F250, .last = 0x1F251 },
    .{ .first = 0x1F260, .last = 0x1F265 },
    .{ .first = 0x1F300, .last = 0x1F320 }, // emoji from here down
    .{ .first = 0x1F32D, .last = 0x1F335 },
    .{ .first = 0x1F337, .last = 0x1F37C },
    .{ .first = 0x1F37E, .last = 0x1F393 },
    .{ .first = 0x1F3A0, .last = 0x1F3CA },
    .{ .first = 0x1F3CF, .last = 0x1F3D3 },
    .{ .first = 0x1F3E0, .last = 0x1F3F0 },
    .{ .first = 0x1F3F4, .last = 0x1F3F4 },
    .{ .first = 0x1F3F8, .last = 0x1F43E },
    .{ .first = 0x1F440, .last = 0x1F440 },
    .{ .first = 0x1F442, .last = 0x1F4FC },
    .{ .first = 0x1F4FF, .last = 0x1F53D },
    .{ .first = 0x1F54B, .last = 0x1F54E },
    .{ .first = 0x1F550, .last = 0x1F567 },
    .{ .first = 0x1F57A, .last = 0x1F57A },
    .{ .first = 0x1F595, .last = 0x1F596 },
    .{ .first = 0x1F5A4, .last = 0x1F5A4 },
    .{ .first = 0x1F5FB, .last = 0x1F64F },
    .{ .first = 0x1F680, .last = 0x1F6C5 },
    .{ .first = 0x1F6CC, .last = 0x1F6CC },
    .{ .first = 0x1F6D0, .last = 0x1F6D2 },
    .{ .first = 0x1F6D5, .last = 0x1F6D7 },
    .{ .first = 0x1F6DC, .last = 0x1F6DF },
    .{ .first = 0x1F6EB, .last = 0x1F6EC },
    .{ .first = 0x1F6F4, .last = 0x1F6FC },
    .{ .first = 0x1F7E0, .last = 0x1F7EB },
    .{ .first = 0x1F7F0, .last = 0x1F7F0 },
    .{ .first = 0x1F90C, .last = 0x1F93A },
    .{ .first = 0x1F93C, .last = 0x1F945 },
    .{ .first = 0x1F947, .last = 0x1F9FF },
    .{ .first = 0x1FA70, .last = 0x1FA7C },
    .{ .first = 0x1FA80, .last = 0x1FA88 },
    .{ .first = 0x1FA90, .last = 0x1FABD },
    .{ .first = 0x1FABF, .last = 0x1FAC5 },
    .{ .first = 0x1FACE, .last = 0x1FADB },
    .{ .first = 0x1FAE0, .last = 0x1FAE8 },
    .{ .first = 0x1FAF0, .last = 0x1FAF8 },
    .{ .first = 0x20000, .last = 0x2FFFD }, // cjk extension B and beyond
    .{ .first = 0x30000, .last = 0x3FFFD },
};

// codepoints that occupy no column of their own: combining marks, joiners,
// bidi controls, and variation selectors. this covers the common blocks, not
// the exhaustive Mn/Me/Cf categories — extend as needed. sorted for binary
// search.
const zero_ranges = [_]Range{
    .{ .first = 0x0300, .last = 0x036F }, // combining diacritical marks
    .{ .first = 0x0483, .last = 0x0489 }, // cyrillic combining
    .{ .first = 0x0591, .last = 0x05BD }, // hebrew points
    .{ .first = 0x05BF, .last = 0x05BF },
    .{ .first = 0x05C1, .last = 0x05C2 },
    .{ .first = 0x05C4, .last = 0x05C5 },
    .{ .first = 0x05C7, .last = 0x05C7 },
    .{ .first = 0x0610, .last = 0x061A }, // arabic marks
    .{ .first = 0x064B, .last = 0x065F },
    .{ .first = 0x0670, .last = 0x0670 },
    .{ .first = 0x06D6, .last = 0x06DC },
    .{ .first = 0x06DF, .last = 0x06E4 },
    .{ .first = 0x06E7, .last = 0x06E8 },
    .{ .first = 0x06EA, .last = 0x06ED },
    .{ .first = 0x0711, .last = 0x0711 }, // syriac
    .{ .first = 0x0730, .last = 0x074A },
    .{ .first = 0x1160, .last = 0x11FF }, // hangul jamo (vowels/finals combine with the lead)
    .{ .first = 0x1AB0, .last = 0x1ACE }, // combining diacritical marks extended
    .{ .first = 0x1DC0, .last = 0x1DFF }, // combining diacritical marks supplement
    .{ .first = 0x200B, .last = 0x200F }, // zwsp, zwnj, zwj, direction marks
    .{ .first = 0x202A, .last = 0x202E }, // bidi controls
    .{ .first = 0x2060, .last = 0x2064 }, // word joiner, invisible operators
    .{ .first = 0x2066, .last = 0x206F },
    .{ .first = 0x20D0, .last = 0x20F0 }, // combining marks for symbols
    // combining kana voicing marks: inside the wide kana block, but they
    // combine — the zero table is checked first, so this wins
    .{ .first = 0x3099, .last = 0x309A },
    .{ .first = 0xFE00, .last = 0xFE0F }, // variation selectors
    .{ .first = 0xFE20, .last = 0xFE2F }, // combining half marks
    .{ .first = 0xFEFF, .last = 0xFEFF }, // zero width no-break space
    .{ .first = 0xE0000, .last = 0xE01EF }, // tags, variation selectors supplement
};

fn inRanges(ranges: []const Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid].first) {
            hi = mid;
        } else if (cp > ranges[mid].last) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

// terminal columns the codepoint occupies: 0 (combining/invisible), 1, or
// 2 (east asian wide/fullwidth). control characters report 0 — they have no
// glyph, and widgets shouldn't be putting them in cells anyway.
pub fn runeWidth(cp: u21) u2 {
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return 0;
    if (cp < 0x300) return 1; // fast path: latin and friends
    if (inRanges(&zero_ranges, cp)) return 0;
    if (inRanges(&wide_ranges, cp)) return 2;
    return 1;
}

// columns a grid cell holding `rune` occupies: 1 or 2. a cell always spans
// at least one column, so zero-width codepoints (which widgets don't merge
// into the preceding cell yet) clamp to 1.
pub fn cellWidth(rune: u21) u2 {
    return @max(1, runeWidth(rune));
}

// total columns the string occupies when every codepoint gets its own cell,
// summing cellWidth. this is how the widgets lay text out, so labels and
// single-line content measure with this.
pub fn displayWidth(s: []const u8) !usize {
    var iter = (try std.unicode.Utf8View.init(s)).iterator();
    var total: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        total += cellWidth(cp);
    }
    return total;
}

// total columns the string occupies, summing runeWidth over its codepoints.
// zero-width codepoints genuinely count 0 here; widgets that give every
// codepoint its own cell should use displayWidth instead.
pub fn strWidth(s: []const u8) !usize {
    var iter = (try std.unicode.Utf8View.init(s)).iterator();
    var total: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        total += runeWidth(cp);
    }
    return total;
}

test "runeWidth basics" {
    try std.testing.expectEqual(@as(u2, 1), runeWidth('a'));
    try std.testing.expectEqual(@as(u2, 1), runeWidth('ö'));
    try std.testing.expectEqual(@as(u2, 2), runeWidth('中')); // cjk ideograph
    try std.testing.expectEqual(@as(u2, 2), runeWidth('あ')); // hiragana
    try std.testing.expectEqual(@as(u2, 2), runeWidth('한')); // hangul syllable
    try std.testing.expectEqual(@as(u2, 2), runeWidth('Ａ')); // fullwidth latin
    try std.testing.expectEqual(@as(u2, 2), runeWidth(0x1F600)); // emoji
    try std.testing.expectEqual(@as(u2, 0), runeWidth(0x0301)); // combining acute
    try std.testing.expectEqual(@as(u2, 0), runeWidth(0x200D)); // zwj
    try std.testing.expectEqual(@as(u2, 0), runeWidth(0x3099)); // combining dakuten
    try std.testing.expectEqual(@as(u2, 1), runeWidth('─')); // box drawing stays narrow
    try std.testing.expectEqual(@as(u2, 1), runeWidth('█'));
}

test "strWidth and cellWidth" {
    try std.testing.expectEqual(@as(usize, 5), try strWidth("hello"));
    try std.testing.expectEqual(@as(usize, 4), try strWidth("中文"));
    try std.testing.expectEqual(@as(usize, 7), try strWidth("abc中文")); // 3 + 4
    try std.testing.expectEqual(@as(usize, 1), try strWidth("e\u{0301}")); // e + combining acute
    try std.testing.expectEqual(@as(u2, 1), cellWidth('a'));
    try std.testing.expectEqual(@as(u2, 2), cellWidth('中'));
    try std.testing.expectEqual(@as(u2, 1), cellWidth('\u{0301}')); // a lone mark still fills its cell
    try std.testing.expectEqual(@as(usize, 7), try displayWidth("abc中文"));
    // per-cell layout gives the combining mark a cell of its own
    try std.testing.expectEqual(@as(usize, 2), try displayWidth("e\u{0301}"));
}
