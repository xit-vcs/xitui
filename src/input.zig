pub const Key = union(enum) {
    unknown,
    arrow_up,
    arrow_down,
    arrow_right,
    arrow_left,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,
    backspace,
    enter,
    tab,
    back_tab,
    escape,
    // function keys, 1 through 12
    f: u4,
    // alt+key, stored as the printable byte that followed the ESC prefix.
    // alt+shift+letter arrives as the uppercase letter. a bare ESC press
    // and an ESC-prefixed byte split across two reads are inherently
    // ambiguous; the parser only reports alt when both bytes arrive in
    // the same read, and otherwise falls back to escape + codepoint.
    alt: u8,
    // ctrl+letter, stored as the lowercase letter ('a'...'z'). ctrl+h,
    // ctrl+i, ctrl+j, and ctrl+m are indistinguishable from backspace,
    // tab, enter, and enter in terminal input, so they arrive as those
    // named keys instead. ctrl+c never arrives because ISIG turns it
    // into a signal.
    ctrl: u8,
    codepoint: u21,
    mouse: Mouse,
    event: enum {
        resize,
    },
};

pub const Mouse = struct {
    x: usize,
    y: usize,
    action: MouseAction,
};

pub const MouseAction = union(enum) {
    press: MouseButton,
    release: MouseButton,
    scroll: ScrollDirection,
};

pub const MouseButton = enum {
    left,
    middle,
    right,
};

pub const ScrollDirection = enum {
    up,
    down,
};
