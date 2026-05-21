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
