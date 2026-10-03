const std = @import("std");
const builtin = @import("builtin");
const inp = @import("./input.zig");
const Size = @import("./layout.zig").Size;
const grd = @import("./grid.zig");
const wth = @import("./width.zig");

const write_buffer_size = 4096;

pub var quit = std.atomic.Value(bool).init(false);
var resized = std.atomic.Value(bool).init(false);

pub const Core = switch (builtin.os.tag) {
    .windows => struct {
        tty: Tty,
        write_buffer: []u8,
        writer: Tty.Writer,
        allocator: std.mem.Allocator,
        parser: EscapeParser,
        high_surrogate: ?u16 = null,

        pub const KEY_EVENT_RECORD = extern struct {
            bKeyDown: std.os.windows.BOOL,
            wRepeatCount: std.os.windows.WORD,
            wVirtualKeyCode: std.os.windows.WORD,
            wVirtualScanCode: std.os.windows.WORD,
            uChar: extern union {
                UnicodeChar: std.os.windows.WCHAR,
                AsciiChar: std.os.windows.CHAR,
            },
            dwControlKeyState: std.os.windows.DWORD,
        };

        pub const MOUSE_EVENT_RECORD = extern struct {
            dwMousePosition: std.os.windows.COORD,
            dwButtonState: std.os.windows.DWORD,
            dwControlKeyState: std.os.windows.DWORD,
            dwEventFlags: std.os.windows.DWORD,
        };

        pub const WINDOW_BUFFER_SIZE_RECORD = extern struct {
            dwSize: std.os.windows.COORD,
        };

        pub const MENU_EVENT_RECORD = extern struct {
            dwCommandId: std.os.windows.UINT,
        };

        pub const FOCUS_EVENT_RECORD = extern struct {
            bSetFocus: std.os.windows.BOOL,
        };

        pub const INPUT_RECORD = extern struct {
            EventType: std.os.windows.WORD,
            Event: extern union {
                KeyEvent: KEY_EVENT_RECORD,
                MouseEvent: MOUSE_EVENT_RECORD,
                WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD,
                MenuEvent: MENU_EVENT_RECORD,
                FocusEvent: FOCUS_EVENT_RECORD,
            },
        };

        pub extern "kernel32" fn ReadConsoleInputW(
            hConsoleInput: std.os.windows.HANDLE,
            lpBuffer: [*]INPUT_RECORD,
            nLength: std.os.windows.DWORD,
            lpNumberOfEventsRead: *std.os.windows.DWORD,
        ) callconv(.winapi) std.os.windows.BOOL;

        pub extern "kernel32" fn PeekConsoleInputW(
            hConsoleInput: std.os.windows.HANDLE,
            lpBuffer: [*]INPUT_RECORD,
            nLength: std.os.windows.DWORD,
            lpNumberOfEventsRead: *std.os.windows.DWORD,
        ) callconv(.winapi) std.os.windows.BOOL;

        pub extern "kernel32" fn GetConsoleMode(
            hConsoleHandle: std.os.windows.HANDLE,
            lpMode: *std.os.windows.DWORD,
        ) callconv(.winapi) std.os.windows.BOOL;

        pub extern "kernel32" fn SetConsoleMode(
            hConsoleHandle: std.os.windows.HANDLE,
            dwMode: std.os.windows.DWORD,
        ) callconv(.winapi) std.os.windows.BOOL;

        pub const SMALL_RECT = extern struct {
            Left: std.os.windows.SHORT,
            Top: std.os.windows.SHORT,
            Right: std.os.windows.SHORT,
            Bottom: std.os.windows.SHORT,
        };

        pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
            dwSize: std.os.windows.COORD,
            dwCursorPosition: std.os.windows.COORD,
            wAttributes: std.os.windows.WORD,
            srWindow: SMALL_RECT,
            dwMaximumWindowSize: std.os.windows.COORD,
        };

        pub extern "kernel32" fn GetConsoleScreenBufferInfo(
            hConsoleOutput: std.os.windows.HANDLE,
            lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
        ) callconv(.winapi) std.os.windows.BOOL;

        pub const HANDLER_ROUTINE = *const fn (dwCtrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;

        pub extern "kernel32" fn SetConsoleCtrlHandler(
            HandlerRoutine: ?HANDLER_ROUTINE,
            Add: std.os.windows.BOOL,
        ) callconv(.winapi) std.os.windows.BOOL;

        pub extern "kernel32" fn WriteConsoleW(
            hConsoleOutput: std.os.windows.HANDLE,
            lpBuffer: [*]const u16,
            nNumberOfCharsToWrite: std.os.windows.DWORD,
            lpNumberOfCharsWritten: ?*std.os.windows.DWORD,
            lpReserved: ?std.os.windows.LPVOID,
        ) callconv(.winapi) std.os.windows.BOOL;

        pub extern "kernel32" fn WaitForSingleObjectEx(
            hHandle: std.os.windows.HANDLE,
            dwMilliseconds: std.os.windows.DWORD,
            bAlertable: std.os.windows.BOOL,
        ) callconv(.winapi) std.os.windows.DWORD;

        pub fn setConsoleCtrlHandler(handler_routine: ?HANDLER_ROUTINE, add: bool) !void {
            const success = SetConsoleCtrlHandler(
                handler_routine,
                if (add) .TRUE else .FALSE,
            );

            if (success == .FALSE) {
                return switch (std.os.windows.GetLastError()) {
                    else => |err| std.os.windows.unexpectedError(err),
                };
            }
        }

        fn ctrlHandler(event: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
            const CTRL_C_EVENT = 0;
            if (event != CTRL_C_EVENT) return .FALSE;
            quit.store(true, .monotonic);
            return .TRUE;
        }

        pub const WaitForSingleObjectError = error{
            WaitAbandoned,
            WaitTimeOut,
            Unexpected,
        };

        pub fn waitForSingleObject(handle: std.os.windows.HANDLE, milliseconds: std.os.windows.DWORD) WaitForSingleObjectError!void {
            return waitForSingleObjectEx(handle, milliseconds, false);
        }

        pub const WAIT_ABANDONED = 0x00000080;
        pub const WAIT_ABANDONED_0 = WAIT_ABANDONED + 0;
        pub const WAIT_OBJECT_0 = 0x00000000;
        pub const WAIT_TIMEOUT = 0x00000102;
        pub const WAIT_FAILED = 0xFFFFFFFF;
        pub const INFINITE = 0xFFFFFFFF;

        pub fn waitForSingleObjectEx(handle: std.os.windows.HANDLE, milliseconds: std.os.windows.DWORD, alertable: bool) WaitForSingleObjectError!void {
            switch (WaitForSingleObjectEx(handle, milliseconds, if (alertable) .TRUE else .FALSE)) {
                WAIT_ABANDONED => return error.WaitAbandoned,
                WAIT_OBJECT_0 => return,
                WAIT_TIMEOUT => return error.WaitTimeOut,
                WAIT_FAILED => switch (std.os.windows.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                },
                else => return error.Unexpected,
            }
        }

        pub const Tty = struct {
            old_out_mode: std.os.windows.DWORD,
            old_in_mode: std.os.windows.DWORD,

            pub const Writer = struct {
                interface: std.Io.Writer,
            };

            fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                if (w.end > 0) {
                    try writeUtf8(w.buffered());
                    return w.consumeAll();
                }
                var consumed: usize = 0;
                for (data, 0..) |bytes, i| {
                    const count = if (i + 1 == data.len) splat else 1;
                    for (0..count) |_| {
                        try writeUtf8(bytes);
                        consumed += bytes.len;
                    }
                }
                return consumed;
            }

            fn writeUtf8(bytes: []const u8) std.Io.Writer.Error!void {
                const out_handle = std.Io.File.stdout().handle;
                var utf16_buffer: [write_buffer_size]u16 = undefined;
                var start: usize = 0;
                while (start < bytes.len) {
                    var end = start + @min(bytes.len - start, write_buffer_size);
                    // keep each utf-8 character together at the chunk boundary
                    while (end < bytes.len and end > start and bytes[end] & 0xc0 == 0x80) end -= 1;
                    if (end == start) return error.WriteFailed;
                    const size = std.unicode.utf8ToUtf16Le(&utf16_buffer, bytes[start..end]) catch return error.WriteFailed;
                    const utf16_bytes = utf16_buffer[0..size];
                    // windows counts utf-16 units, not codepoints
                    var written: usize = 0;
                    while (written < utf16_bytes.len) {
                        const remaining = utf16_bytes[written..];
                        var num_chars_written: std.os.windows.DWORD = undefined;
                        if (WriteConsoleW(out_handle, remaining.ptr, @intCast(remaining.len), &num_chars_written, null) == .FALSE) {
                            return error.WriteFailed;
                        }
                        if (num_chars_written == 0) return error.WriteFailed;
                        written += num_chars_written;
                    }
                    start = end;
                }
            }

            pub fn writer(_: Tty, buffer: []u8) Writer {
                return .{
                    .interface = .{
                        .vtable = &.{ .drain = drain },
                        .buffer = buffer,
                    },
                };
            }
        };

        fn uncook(self: *Core) !void {
            const out_handle = std.Io.File.stdout().handle;
            if (GetConsoleMode(out_handle, &self.tty.old_out_mode) == .FALSE) {
                return error.FailedToGetConsoleMode;
            }
            const ENABLE_PROCESSED_OUTPUT: std.os.windows.DWORD = 0x0001;
            const ENABLE_WRAP_AT_EOL_OUTPUT: std.os.windows.DWORD = 0x0002;
            const ENABLE_VIRTUAL_TERMINAL_PROCESSING: std.os.windows.DWORD = 0x0004;
            // enable processing for the ansi escape codes used by the renderer.
            // virtual terminal processing requires processed output.
            const new_out_mode = (self.tty.old_out_mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING) & ~ENABLE_WRAP_AT_EOL_OUTPUT;
            if (SetConsoleMode(out_handle, new_out_mode) == .FALSE) {
                return error.FailedToSetConsoleMode;
            }
            errdefer _ = SetConsoleMode(out_handle, self.tty.old_out_mode);

            const in_handle = std.Io.File.stdin().handle;
            if (GetConsoleMode(in_handle, &self.tty.old_in_mode) == .FALSE) {
                return error.FailedToGetConsoleMode;
            }
            const ENABLE_WINDOW_INPUT: std.os.windows.DWORD = 0x0008;
            const ENABLE_MOUSE_INPUT: std.os.windows.DWORD = 0x0010;
            const ENABLE_QUICK_EDIT_MODE: std.os.windows.DWORD = 0x0040;
            const ENABLE_EXTENDED_FLAGS: std.os.windows.DWORD = 0x0080;
            const ENABLE_VIRTUAL_TERMINAL_INPUT: std.os.windows.DWORD = 0x0200;
            // ENABLE_EXTENDED_FLAGS is required for ENABLE_QUICK_EDIT_MODE to
            // take effect; quick edit mode would otherwise swallow mouse events.
            // virtual terminal input delivers keys, mouse, and terminal replies
            // as escape sequences, so they decode through the same parser as on
            // posix. mouse input comes from the sequences enableMouse requests,
            // not console mouse events.
            const new_in_mode = (self.tty.old_in_mode | ENABLE_EXTENDED_FLAGS | ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_WINDOW_INPUT) & ~(ENABLE_QUICK_EDIT_MODE | ENABLE_MOUSE_INPUT);
            if (SetConsoleMode(in_handle, new_in_mode) == .FALSE) {
                return error.FailedToSetConsoleMode;
            }
            errdefer _ = SetConsoleMode(in_handle, self.tty.old_in_mode);

            try hideCursor(&self.writer.interface);
            try enterAlt(&self.writer.interface);
            try clearStyle(&self.writer.interface);
            try enableMouse(&self.writer.interface);
            try self.writer.interface.flush();
        }

        fn cook(self: *Core) !void {
            // restore the modes even if writing the cleanup sequences fails
            defer {
                _ = SetConsoleMode(std.Io.File.stdout().handle, self.tty.old_out_mode);
                _ = SetConsoleMode(std.Io.File.stdin().handle, self.tty.old_in_mode);
            }
            try disableMouse(&self.writer.interface);
            try clearStyle(&self.writer.interface);
            try leaveAlt(&self.writer.interface);
            try showCursor(&self.writer.interface);
            try attributeReset(&self.writer.interface);
            try self.writer.interface.flush();
        }

        // virtual terminal input delivers the input stream one utf-16 unit
        // per key-down event
        fn queueKeyEvent(self: *Core, event: KEY_EVENT_RECORD) !void {
            if (event.bKeyDown == .FALSE) return;
            const unit = event.uChar.UnicodeChar;
            // modifier-only key presses carry no character
            if (unit == 0) return;
            if (std.unicode.utf16IsHighSurrogate(unit)) {
                self.high_surrogate = unit;
                return;
            }
            const high = self.high_surrogate;
            self.high_surrogate = null;
            const codepoint: u21 = if (std.unicode.utf16IsLowSurrogate(unit)) blk: {
                const first = high orelse return;
                break :blk std.unicode.utf16DecodeSurrogatePair(&.{ first, unit }) catch unreachable;
            } else unit;
            var utf8: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &utf8) catch return;
            for (0..@max(1, event.wRepeatCount)) |_| try self.parser.queueBytes(utf8[0..len]);
        }

        fn readKey(self: *Core, _: std.Io, blocking: bool) !?inp.Key {
            const in_handle = std.Io.File.stdin().handle;
            while (!quit.load(.monotonic)) {
                if (resized.swap(false, .monotonic)) return .{ .event = .resize };
                if (self.parser.popQueued()) |key| return key;

                // ambiguous input gets a short wait even when not blocking, so a
                // lone escape resolves once the rest of a sequence can't be coming
                const timeout: std.os.windows.DWORD = if (blocking) 100 else if (self.parser.isAmbiguous()) 25 else 0;
                waitForSingleObject(in_handle, timeout) catch |err| switch (err) {
                    error.WaitAbandoned => return null,
                    error.WaitTimeOut => {
                        try self.parser.flushEscape();
                        if (self.parser.popQueued()) |key| return key;
                        if (blocking) continue else return null;
                    },
                    error.Unexpected => |e| return e,
                };
                if (quit.load(.monotonic)) return null;

                var records: [64]INPUT_RECORD = undefined;
                var num_records: std.os.windows.DWORD = undefined;
                if (ReadConsoleInputW(in_handle, &records, records.len, &num_records) == .FALSE) {
                    return error.FailedToReadConsoleInputW;
                }
                for (records[0..num_records]) |record| switch (record.EventType) {
                    // KEY_EVENT
                    0x0001 => try self.queueKeyEvent(record.Event.KeyEvent),
                    // WINDOW_BUFFER_SIZE_EVENT
                    0x0004 => resized.store(true, .monotonic),
                    // MOUSE_EVENT, MENU_EVENT, FOCUS_EVENT
                    0x0002, 0x0008, 0x0010 => {},
                    else => return error.UnrecognizedEventType,
                };
                if (!blocking and num_records == 0) return null;
            }
            return null;
        }
    },
    else => struct {
        tty: std.Io.File,
        write_buffer: []u8,
        writer: std.Io.File.Writer,
        allocator: std.mem.Allocator,
        cooked_termios: std.posix.termios,
        raw: std.posix.termios,
        parser: EscapeParser,

        fn uncook(self: *Core) !void {
            self.cooked_termios = try std.posix.tcgetattr(self.tty.handle);
            errdefer self.cook() catch {};

            self.raw = self.cooked_termios;
            // ECHO must stay off: with it on the terminal echoes input bytes
            // back, and SGR mouse release sequences (which end in lowercase
            // 'm') get interpreted as Select Graphic Rendition — clicking
            // at column 31 would turn text red, etc.
            self.raw.lflag = .{ .ISIG = true, .IEXTEN = true };
            self.raw.iflag = .{ .ICRNL = true, .IUTF8 = true };
            // oflag is left as-is: rendering only uses cursor positioning, so
            // clearing ONLCR gains nothing, and if a parent like `zig build`
            // dies on ctrl+c before we cook, the shell can snapshot our raw
            // state and keep it, skewing the output of later commands.
            self.raw.cflag.CSIZE = .CS8;
            self.raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            self.raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            try std.posix.tcsetattr(self.tty.handle, .FLUSH, self.raw);

            try hideCursor(&self.writer.interface);
            try enterAlt(&self.writer.interface);
            try clearStyle(&self.writer.interface);
            try enableMouse(&self.writer.interface);
            try self.writer.interface.flush();
        }

        fn cook(self: *Core) !void {
            try disableMouse(&self.writer.interface);
            try clearStyle(&self.writer.interface);
            try leaveAlt(&self.writer.interface);
            try showCursor(&self.writer.interface);
            try attributeReset(&self.writer.interface);
            try self.writer.interface.flush();

            try std.posix.tcsetattr(self.tty.handle, .FLUSH, self.cooked_termios);
        }

        fn readKey(self: *Core, io: std.Io, blocking: bool) !?inp.Key {
            if (blocking) {
                // the tty is in raw mode with VMIN=0, VTIME=1, so each
                // non-blocking read already blocks for up to 100 ms. loop on
                // it until a key arrives, the terminal resizes, or we quit.
                while (!quit.load(.monotonic)) {
                    if (resized.swap(false, .monotonic)) return .{ .event = .resize };
                    if (try self.readKey(io, false)) |key| return key;
                }

                return null;
            } else {
                if (resized.swap(false, .monotonic)) {
                    return .{ .event = .resize };
                }

                if (self.parser.popQueued()) |key| return key;

                const buffer_size = 32;
                var buffer: [buffer_size]u8 = undefined;
                const size = self.tty.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => |e| return e,
                };
                if (size == 0) {
                    // the timed read went idle; resolve a lone escape only
                    // after giving the rest of a split sequence time to arrive
                    try self.parser.flushEscape();
                } else {
                    try self.parser.queueBytes(buffer[0..size]);
                }
                return self.parser.popQueued();
            }
        }
    },
};

pub const Terminal = struct {
    core: Core,
    size: Size,
    render_state: RenderState,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !Terminal {
        switch (builtin.os.tag) {
            .windows => {
                const tty = Core.Tty{
                    .old_out_mode = undefined,
                    .old_in_mode = undefined,
                };

                var parser = try EscapeParser.init(allocator);
                errdefer parser.deinit();

                const write_buffer = try allocator.alloc(u8, write_buffer_size);
                errdefer allocator.free(write_buffer);

                var self = Terminal{
                    .core = .{
                        .tty = tty,
                        .write_buffer = write_buffer,
                        .writer = tty.writer(write_buffer),
                        .allocator = allocator,
                        .parser = parser,
                    },
                    .size = .{ .width = 0, .height = 0 },
                    .render_state = RenderState.init(allocator),
                };

                try self.core.uncook();
                errdefer self.core.cook() catch {};

                quit.store(false, .monotonic);
                try Core.setConsoleCtrlHandler(Core.ctrlHandler, true);
                errdefer Core.setConsoleCtrlHandler(Core.ctrlHandler, false) catch {};

                try self.core.writer.interface.writeAll("\x1B[?1049h"); // clear screen
                try self.core.writer.interface.flush();
                self.size = try self.getSize();

                return self;
            },
            else => {
                var tty = try std.Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write });
                errdefer tty.close(io);

                var parser = try EscapeParser.init(allocator);
                errdefer parser.deinit();

                const write_buffer = try allocator.alloc(u8, write_buffer_size);
                errdefer allocator.free(write_buffer);

                var self = Terminal{
                    .core = .{
                        .tty = tty,
                        .write_buffer = write_buffer,
                        .writer = tty.writer(io, write_buffer),
                        .allocator = allocator,
                        .cooked_termios = undefined,
                        .raw = undefined,
                        .parser = parser,
                    },
                    .size = .{ .width = 0, .height = 0 },
                    .render_state = RenderState.init(allocator),
                };

                try self.core.uncook();
                errdefer self.core.cook() catch {};

                const handler = struct {
                    fn run(_: std.posix.SIG) callconv(.c) void {
                        quit.store(true, .monotonic);
                    }
                }.run;
                std.posix.sigaction(std.posix.SIG.INT, &.{
                    .handler = .{ .handler = handler },
                    .mask = std.posix.sigemptyset(),
                    .flags = 0,
                }, null);

                const resize_handler = struct {
                    fn run(_: std.posix.SIG) callconv(.c) void {
                        resized.store(true, .monotonic);
                    }
                }.run;
                std.posix.sigaction(std.posix.SIG.WINCH, &.{
                    .handler = .{ .handler = resize_handler },
                    .mask = std.posix.sigemptyset(),
                    .flags = 0,
                }, null);

                // set non-blocking
                self.core.raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
                self.core.raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
                try std.posix.tcsetattr(self.core.tty.handle, .NOW, self.core.raw);

                self.size = try self.getSize();

                return self;
            },
        }
    }

    pub fn deinit(self: *Terminal, io: std.Io) void {
        self.render_state.deinit();
        switch (builtin.os.tag) {
            .windows => {
                Core.setConsoleCtrlHandler(Core.ctrlHandler, false) catch {};
                self.core.cook() catch {};
                self.core.parser.deinit();
                self.core.allocator.free(self.core.write_buffer);
            },
            else => {
                self.core.cook() catch {};
                self.core.parser.deinit();
                self.core.allocator.free(self.core.write_buffer);
                self.core.tty.close(io);
            },
        }
    }

    pub fn getSize(self: *const Terminal) !Size {
        switch (builtin.os.tag) {
            .windows => {
                const out_handle = std.Io.File.stdout().handle;
                var info: Core.CONSOLE_SCREEN_BUFFER_INFO = undefined;
                if (Core.GetConsoleScreenBufferInfo(out_handle, &info) == .FALSE) {
                    return error.FailedToGetConsoleScreenBufferInfo;
                }
                const width = info.srWindow.Right - info.srWindow.Left + 1;
                const height = info.srWindow.Bottom - info.srWindow.Top + 1;
                return .{
                    .width = if (width < 0) 0 else @intCast(width),
                    .height = if (height < 0) 0 else @intCast(height),
                };
            },
            else => {
                var win_size = std.mem.zeroes(std.posix.winsize);
                const rc = std.posix.system.ioctl(self.core.tty.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&win_size));
                switch (std.posix.errno(rc)) {
                    .SUCCESS => {},
                    else => |err| return std.posix.unexpectedErrno(err),
                }
                return .{
                    .width = win_size.col,
                    .height = win_size.row,
                };
            },
        }
    }

    pub fn readKey(self: *Terminal, io: std.Io, blocking: bool) !?inp.Key {
        return self.core.readKey(io, blocking) catch |err| {
            // ignore error if terminal is quitting (SIGINT was sent)
            if (quit.load(.monotonic)) {
                return null;
            } else {
                return err;
            }
        };
    }

    pub fn shouldQuit(_: *const Terminal) bool {
        return quit.load(.monotonic);
    }

    pub fn requestQuit(_: *Terminal) void {
        quit.store(true, .monotonic);
    }

    // put the terminal back into its cooked state (leave the alternate screen,
    // show the cursor, restore the original mode). safe to call from a panic
    // handler so a crash's stack trace is printed on a usable terminal instead
    // of being mangled by raw mode and the alternate buffer.
    pub fn restore(self: *Terminal) void {
        self.core.cook() catch {};
    }

    // see writeBackgroundQuery; the reply arrives through readKey
    pub fn queryBackground(self: *Terminal) !void {
        try writeBackgroundQuery(&self.core.writer.interface);
        try self.core.writer.interface.flush();
    }

    // fill the terminal behind any cell with no bg of its own
    pub fn setBackground(self: *Terminal, background: ?grd.Grid.Color) void {
        self.render_state.background = background;
    }

    pub fn render(self: *Terminal, root_widget: anytype) !bool {
        self.size = self.getSize() catch |err| {
            // ignore error if terminal is quitting (SIGINT was sent)
            if (quit.load(.monotonic)) {
                return true;
            } else {
                return err;
            }
        };

        return try renderToWriter(
            &self.core.writer.interface,
            &self.render_state,
            root_widget,
            self.size,
        );
    }
};

pub const RenderState = struct {
    allocator: std.mem.Allocator,
    // the last frame's cells, with their links swapped for `last_links`
    last_grid: ?grd.Grid = null,
    // a hash of each snapshot cell's link (0 for none). the frame's link
    // strings may be freed once it's drawn, so only their hashes are kept.
    last_links: []u64 = &.{},
    last_size: ?Size = null,
    // whole-terminal background, shown under any cell whose bg is null.
    // changing it forces a full refresh on the next render.
    background: ?grd.Grid.Color = null,
    last_background: ?grd.Grid.Color = null,
    // draw without colors, keeping other attributes like bold (see
    // no-color.org). set it before the first render.
    no_color: bool = false,

    pub fn init(allocator: std.mem.Allocator) RenderState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RenderState) void {
        self.replaceGrid(null) catch unreachable;
    }

    // a fresh, blank snapshot of `size`, or none
    fn replaceGrid(self: *RenderState, size: ?Size) !void {
        if (self.last_grid) |*grid| grid.deinit();
        self.last_grid = null;
        self.allocator.free(self.last_links);
        self.last_links = &.{};
        const new_size = size orelse return;
        var grid = try grd.Grid.init(self.allocator, new_size);
        errdefer grid.deinit();
        const links = try self.allocator.alloc(u64, grid.cells.len);
        @memset(links, 0);
        self.last_grid = grid;
        self.last_links = links;
    }
};

pub fn renderToWriter(
    writer: *std.Io.Writer,
    state: *RenderState,
    root_widget: anytype,
    size: Size,
) !bool {
    if (size.width == 0 or size.height == 0) {
        // invalidate the rendered size so restoring the viewport forces a full
        // refresh, even when it returns to the dimensions it had before.
        state.last_size = size;
        return false;
    }

    const size_changed = if (state.last_size) |last_size|
        last_size.width != size.width or last_size.height != size.height
    else
        true;

    // a new terminal size changes the root constraint, so rebuild before
    // deciding which grid transition this frame represents.
    if (size_changed) {
        try root_widget.build(state.allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = size.width, .height = size.height },
        }, root_widget.getFocus());
    }

    const current_grid = root_widget.getGrid();
    const background_changed = !std.meta.eql(state.background, state.last_background);
    var force_refresh = size_changed or background_changed;
    // only allocate a snapshot when its dimensions change
    if (current_grid) |grid| {
        const needs_snapshot = if (state.last_grid) |last_grid|
            last_grid.size.width != grid.size.width or last_grid.size.height != grid.size.height
        else
            true;
        if (needs_snapshot) {
            try state.replaceGrid(grid.size);
            force_refresh = true;
        }
    } else if (state.last_grid != null) {
        try state.replaceGrid(null);
        force_refresh = true;
    }

    var started = false;
    // track terminal state to avoid per-cell escapes
    var style: grd.Grid.Style = .{};
    // the hash of the hyperlink the terminal has open (0 for none)
    var open_link: u64 = 0;
    errdefer {
        // a partial frame needs a full redraw, including reused snapshot cells
        state.last_size = null;
        state.last_background = null;
        if (started) {
            if (open_link != 0) writeLink(writer, null) catch {};
            attributeReset(writer) catch {};
            writer.writeAll("\x1B[?2026l") catch {};
            writer.flush() catch {};
        }
    }

    if (force_refresh) {
        started = true;
        try writer.writeAll("\x1B[?2026h");
        // paint the cleared spaces with the terminal background, so empty
        // default cells can still be skipped below
        if (state.background) |bg| {
            if (!state.no_color) {
                style = .{ .bg = bg };
                try writeStyle(writer, style);
            }
        }
        try clearRect(writer, 0, 0, size);
    }

    var grid_changed = force_refresh;
    if (current_grid) |grid| {
        if (state.last_grid) |last_grid| {
            // compare and update the snapshot in one pass
            for (0..grid.size.height) |y| {
                // force a cursor move to cancel any pending wrap
                var cursor_x: ?usize = null;
                const row_start = y * grid.size.width;
                const row = grid.cells[row_start..][0..grid.size.width];
                const last_row = last_grid.cells[row_start..][0..grid.size.width];
                const last_link_row = state.last_links[row_start..][0..grid.size.width];
                for (row, last_row, last_link_row, 0..) |cell, *last_cell, *last_link, x| {
                    // an unsafe url is drawn without a link
                    const cell_link = if (cell.link) |l| (if (isSafeLink(l)) l else null) else null;
                    const link_hash = if (cell_link) |l| std.hash.Wyhash.hash(0, l) | 1 else 0;
                    var unlinked = cell;
                    unlinked.link = null;
                    if (!force_refresh and unlinked.eql(last_cell.*) and link_hash == last_link.*) continue;
                    grid_changed = true;
                    last_cell.* = unlinked;
                    last_link.* = link_hash;

                    if (cell.continuation) continue;
                    // the clear already drew blank cells, unless they carry a link
                    if (force_refresh and cell.rune == null and cell.style.eql(.{}) and link_hash == 0) continue;
                    var cell_style = cell.style;
                    if (state.no_color) {
                        cell_style.fg = null;
                        cell_style.bg = null;
                    } else {
                        cell_style.bg = cell_style.bg orelse state.background;
                    }
                    // off-screen cursor moves clamp to the edge
                    if (x >= size.width or y >= size.height) continue;
                    var rune = cell.rune orelse ' ';
                    // a control character would move the cursor instead of drawing
                    if (rune < 0x20 or (rune >= 0x7f and rune < 0xa0)) rune = ' ';
                    if (wth.cellWidth(rune) > size.width - x) rune = ' ';
                    // keep unchanged frames silent
                    if (!started) {
                        started = true;
                        try writer.writeAll("\x1B[?2026h");
                    }

                    // only trust ascii cursor advances; unicode widths vary by terminal
                    const advances = rune >= 0x20 and rune < 0x7f;
                    if (!advances or cursor_x != x) {
                        try moveCursor(writer, x, y);
                    }
                    if (!style.eql(cell_style)) {
                        if (!style.eql(.{})) try attributeReset(writer);
                        try writeStyle(writer, cell_style);
                        style = cell_style;
                    }
                    if (link_hash != open_link) {
                        try writeLink(writer, cell_link);
                        open_link = link_hash;
                    }

                    var encoded: [4]u8 = undefined;
                    const len = try std.unicode.utf8Encode(rune, &encoded);
                    try writer.writeAll(encoded[0..len]);
                    cursor_x = if (advances) x + 1 else null;
                }
            }
        }
    }

    if (started) {
        if (open_link != 0) try writeLink(writer, null);
        if (!style.eql(.{})) try attributeReset(writer);
        try writer.writeAll("\x1B[?2026l");
        started = false;
        try writer.flush();
    }
    state.last_size = size;
    state.last_background = state.background;
    return grid_changed;
}

// emit the sgr sequences for a style, assuming attributes were just reset
pub fn writeStyle(writer: *std.Io.Writer, style: grd.Grid.Style) !void {
    if (style.bold) try writer.writeAll("\x1B[1m");
    if (style.dim) try writer.writeAll("\x1B[2m");
    if (style.italic) try writer.writeAll("\x1B[3m");
    if (style.underline) try writer.writeAll("\x1B[4m");
    if (style.strikethrough) try writer.writeAll("\x1B[9m");
    if (style.inverted) try writer.writeAll("\x1B[7m");
    if (style.fg) |c| try writeColor(writer, c, false);
    if (style.bg) |c| try writeColor(writer, c, true);
}

// open an osc 8 hyperlink to `url`, or close the open one when null
fn writeLink(writer: *std.Io.Writer, url: ?[]const u8) !void {
    try writer.writeAll("\x1B]8;;");
    if (url) |u| try writer.writeAll(u);
    try writer.writeAll("\x1B\\");
}

// whether `url` can go in an osc 8 sequence: printable ascii without
// spaces, so it can't end the sequence early or smuggle in escapes
fn isSafeLink(url: []const u8) bool {
    if (url.len == 0) return false;
    for (url) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

fn writeColor(writer: *std.Io.Writer, color: grd.Grid.Color, background: bool) !void {
    switch (color) {
        .ansi => |ansi| {
            const n = @intFromEnum(ansi);
            // 30-37 / 40-47 for the normal colors, 90-97 / 100-107 for bright
            const base: u8 = if (n < 8) 30 else 90;
            const code = base + (n % 8) + @as(u8, if (background) 10 else 0);
            try writeControl(writer, "\x1B[{d}m", .{code});
        },
        .indexed => |n| try writeControl(writer, "\x1B[{d};5;{d}m", .{ @as(u8, if (background) 48 else 38), n }),
        .rgb => |c| try writeControl(writer, "\x1B[{d};2;{d};{d};{d}m", .{ @as(u8, if (background) 48 else 38), c.r, c.g, c.b }),
    }
}

pub fn moveCursor(writer: *std.Io.Writer, x: usize, y: usize) !void {
    try writeControl(writer, "\x1B[{};{}H", .{ y + 1, x + 1 });
}

fn writeControl(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) !void {
    var buffer: [64]u8 = undefined;
    const control = std.fmt.bufPrint(&buffer, format, args) catch return error.WriteFailed;
    try writer.writeAll(control);
}

pub fn enterAlt(writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1B[s"); // save cursor position
    try writer.writeAll("\x1B[?47h"); // save screen
    try writer.writeAll("\x1B[?1049h"); // enable alternative buffer
}

pub fn leaveAlt(writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1B[?1049l"); // disable alternative buffer
    try writer.writeAll("\x1B[?47l"); // restore screen
    try writer.writeAll("\x1B[u"); // restore cursor position
}

pub fn hideCursor(writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1B[?25l");
}

pub fn showCursor(writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1B[?25h");
}

pub fn attributeReset(writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1B[0m");
}

pub fn blueBackground(writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1B[44m");
}

pub fn clearStyle(writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1B[2J");
}

pub fn enableMouse(writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1B[?1000h"); // button-event tracking
    try writer.writeAll("\x1B[?1006h"); // SGR extended coordinates
}

pub fn disableMouse(writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1B[?1006l");
    try writer.writeAll("\x1B[?1000l");
}

// ask for the default background color (OSC 11). a terminal that supports it
// replies with a sequence the parser reports as a background event.
pub fn writeBackgroundQuery(writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1B]11;?\x1B\\");
}

// the body of an OSC 11 reply after "11;": "rgb:R/G/B" with 1 to 4 hex digits per channel
fn parseBackgroundReport(body: []const u8) ?grd.Grid.Color.Rgb {
    const prefix = "rgb:";
    if (!std.mem.startsWith(u8, body, prefix)) return null;
    var channels = std.mem.splitScalar(u8, body[prefix.len..], '/');
    var rgb: [3]u8 = undefined;
    for (&rgb) |*channel| {
        const hex = channels.next() orelse return null;
        if (hex.len > 4) return null;
        const value = std.fmt.parseInt(u32, hex, 16) catch return null;
        const max = (@as(u32, 1) << @intCast(hex.len * 4)) - 1;
        channel.* = @intCast((value * 255 + max / 2) / max);
    }
    if (channels.next() != null) return null;
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}

fn parseSgrMouse(buffer: []const u8, press: bool) ?inp.Key {
    // buffer at this point looks like: ESC '[' '<' Cb ';' Cx ';' Cy
    if (buffer.len < 4) return null;
    if (buffer[0] != '\x1B' or buffer[1] != '[' or buffer[2] != '<') return null;

    var parts = std.mem.splitScalar(u8, buffer[3..], ';');
    const cb_str = parts.next() orelse return null;
    const cx_str = parts.next() orelse return null;
    const cy_str = parts.next() orelse return null;

    const cb = std.fmt.parseInt(u16, cb_str, 10) catch return null;
    const cx = std.fmt.parseInt(usize, cx_str, 10) catch return null;
    const cy = std.fmt.parseInt(usize, cy_str, 10) catch return null;

    const x: usize = if (cx > 0) cx - 1 else 0;
    const y: usize = if (cy > 0) cy - 1 else 0;
    const ctrl = cb & 0x10 != 0;

    // bit 6 (0x40) flags a wheel event; lower bit is direction
    if (cb & 0x40 != 0) {
        const dir: inp.ScrollDirection = if (cb & 0x01 == 0) .up else .down;
        return .{ .mouse = .{ .x = x, .y = y, .action = .{ .scroll = dir }, .ctrl = ctrl } };
    }

    const button: inp.MouseButton = switch (cb & 0x03) {
        0 => .left,
        1 => .middle,
        2 => .right,
        // 3 means "no button" (motion-release in legacy mode); ignore
        else => return null,
    };
    return .{ .mouse = .{
        .x = x,
        .y = y,
        .action = if (press) .{ .press = button } else .{ .release = button },
        .ctrl = ctrl,
    } };
}

pub fn clearRect(writer: *std.Io.Writer, x: usize, y: usize, size: Size) !void {
    for (0..size.height) |i| {
        try moveCursor(writer, x, y + i);
        for (0..size.width) |_| {
            try writer.writeByte(' ');
        }
    }
}

pub const EscapeParser = struct {
    allocator: std.mem.Allocator,
    esc_buffer: [esc_buffer_size]u8,
    esc_len: usize,
    key_queue: std.ArrayList(inp.Key),
    key_index: usize,
    // the buffered sequence outgrew esc_buffer. its remaining bytes are still
    // consumed up to the terminator, then it reports as one unknown key.
    esc_overflowed: bool,
    // an incomplete utf-8 codepoint at the end of the last byte feed
    utf8_buffer: [4]u8,
    utf8_len: usize,

    // fits the reports terminals send unprompted (device attributes, cursor
    // position, mode queries); anything longer is swallowed, not parsed.
    const esc_buffer_size = 128;

    // only OSC 11 is parsed. until its prefix matches, the bytes may be alt+]
    // followed by typing.
    const osc_prefix = "\x1B]11;";

    pub fn init(allocator: std.mem.Allocator) !EscapeParser {
        return .{
            .allocator = allocator,
            .esc_buffer = undefined,
            .esc_len = 0,
            .key_queue = .empty,
            .key_index = 0,
            .esc_overflowed = false,
            .utf8_buffer = undefined,
            .utf8_len = 0,
        };
    }

    pub fn deinit(self: *EscapeParser) void {
        self.key_queue.deinit(self.allocator);
    }

    pub fn popQueued(self: *EscapeParser) ?inp.Key {
        if (self.key_index == self.key_queue.items.len) return null;
        const key = self.key_queue.items[self.key_index];
        self.key_index += 1;
        if (self.key_index == self.key_queue.items.len) {
            self.key_queue.clearRetainingCapacity();
            self.key_index = 0;
        }
        return key;
    }

    fn append(self: *EscapeParser, key: inp.Key) !void {
        // reuse consumed space when the array fills, but wait until at least
        // half was consumed so alternating reads and writes don't keep copying
        if (self.key_queue.items.len == self.key_queue.capacity and
            self.key_index > 0 and self.key_index >= self.key_queue.items.len / 2)
        {
            const pending = self.key_queue.items[self.key_index..];
            std.mem.copyForwards(inp.Key, self.key_queue.items[0..pending.len], pending);
            self.key_queue.items.len = pending.len;
            self.key_index = 0;
        }
        try self.key_queue.append(self.allocator, key);
    }

    fn appendScratch(self: *EscapeParser, byte: u8) void {
        self.esc_buffer[self.esc_len] = byte;
        self.esc_len += 1;
    }

    // drop a partially-buffered escape sequence without reporting anything
    pub fn clearScratch(self: *EscapeParser) void {
        self.esc_len = 0;
        self.esc_overflowed = false;
    }

    // decode `bytes` and queue every key they yield, in arrival order. a
    // sequence cut off at the end stays buffered until the rest arrives, so
    // input may be fed in arbitrary chunks.
    pub fn queueBytes(self: *EscapeParser, bytes: []const u8) !void {
        for (bytes) |byte| try self.queueByte(byte);
    }

    fn queueByte(self: *EscapeParser, byte: u8) !void {
        if (self.utf8_len == 0) {
            const len = std.unicode.utf8ByteSequenceLength(byte) catch return;
            if (len == 1) return self.writeCodepoint(byte);
            self.utf8_buffer[0] = byte;
            self.utf8_len = 1;
            return;
        }

        // a new leading byte abandons a malformed partial codepoint but still
        // gets processed itself
        if (byte & 0xc0 != 0x80) {
            self.utf8_len = 0;
            return self.queueByte(byte);
        }

        self.utf8_buffer[self.utf8_len] = byte;
        self.utf8_len += 1;
        const expected = std.unicode.utf8ByteSequenceLength(self.utf8_buffer[0]) catch unreachable;
        if (self.utf8_len < expected) return;

        const codepoint = std.unicode.utf8Decode(self.utf8_buffer[0..self.utf8_len]) catch {
            self.utf8_len = 0;
            return;
        };
        self.utf8_len = 0;
        try self.writeCodepoint(codepoint);
    }

    // whether the buffered input awaits flushEscape: a lone ESC, a sequence
    // introducer that may be alt+[, alt+O, or alt+], or a partial OSC 11 prefix
    // that may be alt+] followed by typing
    pub fn isAmbiguous(self: *const EscapeParser) bool {
        return self.esc_len == 1 or self.esc_len == 2 or self.inOscPrefix();
    }

    fn inOscPrefix(self: *const EscapeParser) bool {
        return self.esc_len >= 2 and self.esc_len < osc_prefix.len and self.esc_buffer[1] == ']';
    }

    // resolve ambiguous input once nothing more is coming: a held-back ESC is
    // the escape key, a lone introducer is an alt combo, and a partial OSC 11
    // prefix is alt+] and typed keys. a longer partial sequence is unaffected,
    // since it may still complete.
    pub fn flushEscape(self: *EscapeParser) !void {
        if (self.esc_len == 1) {
            self.clearScratch();
            try self.append(.escape);
        } else if (self.inOscPrefix()) {
            try self.replayOscPrefix();
        } else if (self.esc_len == 2) {
            const byte = self.esc_buffer[1];
            self.clearScratch();
            try self.append(.{ .alt = byte });
        }
    }

    // report a partial OSC 11 prefix as alt+] and replay the bytes after it
    fn replayOscPrefix(self: *EscapeParser) std.mem.Allocator.Error!void {
        var replay_buf: [osc_prefix.len]u8 = undefined;
        const replay = replay_buf[0 .. self.esc_len - 2];
        @memcpy(replay, self.esc_buffer[2..self.esc_len]);
        self.clearScratch();
        try self.append(.{ .alt = ']' });
        for (replay) |b| try self.writeCodepoint(b);
    }

    // give up on the buffered sequence: a lone ESC was the escape key, and a
    // longer fragment is unparseable and reports as a single unknown key.
    fn abortSequence(self: *EscapeParser) !void {
        const lone_esc = self.esc_len == 1;
        self.clearScratch();
        try self.append(if (lone_esc) .escape else .unknown);
    }

    // decode a codepoint that isn't part of an escape sequence
    fn plainKey(codepoint: u21) inp.Key {
        if (codepoint == 8 or codepoint == 127) return .backspace;
        if (codepoint == 13 or codepoint == 10) return .enter;
        if (codepoint == 9) return .tab;
        // remaining C0 control chars are ctrl+letter (0x01 == ctrl+a)
        if (codepoint >= 0x01 and codepoint <= 0x1A) return .{ .ctrl = @intCast(codepoint - 0x01 + 'a') };
        return .{ .codepoint = codepoint };
    }

    fn writeCodepoint(self: *EscapeParser, codepoint: u21) !void {
        // not in an esc sequence
        if (self.esc_len == 0) {
            // hold the ESC back: the next byte decides whether it opens a
            // sequence, completes an alt combo, or was the escape key
            if (codepoint == '\x1B') {
                self.appendScratch('\x1B');
                return;
            }
            return self.append(plainKey(codepoint));
        }

        // esc sequences are ascii-only, so a multi-byte codepoint ends the
        // buffered one and stands on its own
        const byte: u8 = std.math.cast(u8, codepoint) orelse {
            try self.abortSequence();
            return self.append(plainKey(codepoint));
        };

        // the byte after ESC either opens a CSI/SS3/OSC sequence or completes
        // an alt combo; anything non-printable means the ESC was the escape key
        if (self.esc_len == 1) {
            if (byte == '[' or byte == 'O' or byte == ']') {
                self.appendScratch(byte);
                return;
            }
            self.clearScratch();
            if (byte >= 0x20 and byte < 0x7F) return self.append(.{ .alt = byte });
            try self.append(.escape);
            // a second ESC opens the next sequence rather than decoding here
            if (byte == '\x1B') {
                self.appendScratch('\x1B');
                return;
            }
            return self.append(plainKey(codepoint));
        }

        // an OSC sequence runs until BEL or ST (ESC \)
        if (self.esc_buffer[1] == ']') {
            if (self.esc_len < osc_prefix.len and byte != osc_prefix[self.esc_len]) {
                try self.replayOscPrefix();
                return self.writeCodepoint(codepoint);
            }
            const st = byte == '\\' and self.esc_buffer[self.esc_len - 1] == '\x1B';
            if (byte == 0x07 or st) {
                const body_end = if (st) self.esc_len - 1 else self.esc_len;
                const report = if (self.esc_overflowed) null else parseBackgroundReport(self.esc_buffer[osc_prefix.len..body_end]);
                const key: inp.Key = if (report) |rgb| .{ .event = .{ .background = rgb } } else .unknown;
                self.clearScratch();
                return self.append(key);
            }
            if (self.esc_len == self.esc_buffer.len) {
                // keep the last byte current so an ST is still recognized
                self.esc_overflowed = true;
                self.esc_buffer[self.esc_len - 1] = byte;
            } else {
                self.appendScratch(byte);
            }
            return;
        }

        switch (byte) {
            // chars that terminate the sequence
            0x40...0x7E => {
                const key: inp.Key = if (self.esc_overflowed) .unknown else switch (byte) {
                    'A' => .arrow_up,
                    'B' => .arrow_down,
                    'C' => .arrow_right,
                    'D' => .arrow_left,
                    'F' => .end,
                    'H' => .home,
                    // shift+tab — xterm-style "CSI Z"
                    'Z' => .back_tab,
                    // F1–F4 — SS3-style "ESC O P" through "ESC O S"
                    // (also the terminator of modified CSI forms
                    // like "CSI 1;2P", whose modifier we ignore)
                    'P' => .{ .f = 1 },
                    'Q' => .{ .f = 2 },
                    'R' => .{ .f = 3 },
                    'S' => .{ .f = 4 },
                    'M', 'm' => parseSgrMouse(self.esc_buffer[0..self.esc_len], byte == 'M') orelse .unknown,
                    '~' => blk: {
                        var codes = std.mem.splitSequence(u8, self.esc_buffer[2..self.esc_len], ";");
                        const code = codes.first();
                        break :blk if (std.mem.eql(u8, code, "1"))
                            .home
                        else if (std.mem.eql(u8, code, "2"))
                            .insert
                        else if (std.mem.eql(u8, code, "3"))
                            .delete
                        else if (std.mem.eql(u8, code, "4"))
                            .end
                        else if (std.mem.eql(u8, code, "5"))
                            .page_up
                        else if (std.mem.eql(u8, code, "6"))
                            .page_down
                            // F1–F12 — the historical code sequence
                            // has gaps at 16 and 22
                        else if (std.mem.eql(u8, code, "11"))
                            inp.Key{ .f = 1 }
                        else if (std.mem.eql(u8, code, "12"))
                            inp.Key{ .f = 2 }
                        else if (std.mem.eql(u8, code, "13"))
                            inp.Key{ .f = 3 }
                        else if (std.mem.eql(u8, code, "14"))
                            inp.Key{ .f = 4 }
                        else if (std.mem.eql(u8, code, "15"))
                            inp.Key{ .f = 5 }
                        else if (std.mem.eql(u8, code, "17"))
                            inp.Key{ .f = 6 }
                        else if (std.mem.eql(u8, code, "18"))
                            inp.Key{ .f = 7 }
                        else if (std.mem.eql(u8, code, "19"))
                            inp.Key{ .f = 8 }
                        else if (std.mem.eql(u8, code, "20"))
                            inp.Key{ .f = 9 }
                        else if (std.mem.eql(u8, code, "21"))
                            inp.Key{ .f = 10 }
                        else if (std.mem.eql(u8, code, "23"))
                            inp.Key{ .f = 11 }
                        else if (std.mem.eql(u8, code, "24"))
                            inp.Key{ .f = 12 }
                        else
                            .unknown;
                    },
                    else => .unknown,
                };
                self.clearScratch();
                return self.append(key);
            },
            // a sequence too long to buffer can't be parsed, but its bytes
            // must still be consumed so the tail doesn't leak out as keys
            else => if (self.esc_len == self.esc_buffer.len) {
                self.esc_overflowed = true;
            } else {
                self.appendScratch(byte);
            },
        }
    }
};

//
// cooking the terminal on panic/segfault
//

// the terminal a crash handler should cook before a stack trace is printed. an
// app registers its terminal with setActive once it lives at its final address
// (Terminal.init returns by value, so this can't be done inside init).
var active_terminal = std.atomic.Value(?*Terminal).init(null);

pub fn setActive(terminal: ?*Terminal) void {
    active_terminal.store(terminal, .monotonic);
}

// std.debug calls this just before it dumps a panic or signal (SIGSEGV/SIGILL/
// SIGBUS/SIGFPE) stack trace
fn crashHandler(_: ?*anyopaque) void {
    if (active_terminal.load(.monotonic)) |t| t.restore();
}

// a drop-in for std's debug io that behaves identically except it cooks the
// active terminal on a crash
const default_debug_io = std.Io.Threaded.global_single_threaded.io();
const crash_vtable: std.Io.VTable = blk: {
    var vt = default_debug_io.vtable.*;
    vt.crashHandler = crashHandler;
    break :blk vt;
};
pub const crash_debug_io: std.Io = .{
    .userdata = default_debug_io.userdata,
    .vtable = &crash_vtable,
};
