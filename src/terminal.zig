const std = @import("std");
const builtin = @import("builtin");
const inp = @import("./input.zig");
const Size = @import("./layout.zig").Size;
const grd = @import("./grid.zig");

const write_buffer_size = 4096;

pub var quit = std.atomic.Value(bool).init(false);
var resized = std.atomic.Value(bool).init(false);

pub const Core = switch (builtin.os.tag) {
    .windows => struct {
        tty: Tty,
        write_buffer: []u8,
        writer: Tty.Writer,
        allocator: std.mem.Allocator,
        last_mouse_buttons: std.os.windows.DWORD,

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

            fn drain(w: *std.Io.Writer, _: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                // splat isn't supported for now
                if (splat != 1) return error.WriteFailed;

                const utf8_bytes = w.buffered();

                var utf16_buffer = [_]u16{0} ** write_buffer_size;
                const size = std.unicode.utf8ToUtf16Le(&utf16_buffer, utf8_bytes) catch return error.WriteFailed;
                const utf16_bytes = utf16_buffer[0..size];

                const num_chars = std.unicode.utf16CountCodepoints(utf16_bytes) catch return error.WriteFailed;
                var num_chars_written: std.os.windows.DWORD = undefined;

                const out_handle = std.Io.File.stdout().handle;
                if (WriteConsoleW(out_handle, utf16_bytes.ptr, @intCast(num_chars), &num_chars_written, null) == .FALSE) {
                    return error.WriteFailed;
                }

                // return the number of bytes written
                if (num_chars == num_chars_written) {
                    return w.consume(utf8_bytes.len);
                } else {
                    const text = std.unicode.Utf8View.init(utf8_bytes) catch return error.WriteFailed;
                    var iter = text.iterator();
                    var bytes_written: usize = 0;
                    for (0..num_chars_written) |_| {
                        const slice = iter.nextCodepointSlice() orelse return error.WriteFailed;
                        bytes_written += slice.len;
                    }
                    return w.consume(bytes_written);
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
            const ENABLE_WRAP_AT_EOL_OUTPUT: std.os.windows.DWORD = 0x0002;
            const new_out_mode = self.tty.old_out_mode & ~ENABLE_WRAP_AT_EOL_OUTPUT;
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
            // ENABLE_EXTENDED_FLAGS is required for ENABLE_QUICK_EDIT_MODE to
            // take effect; quick edit mode would otherwise swallow mouse events.
            const new_in_mode = (self.tty.old_in_mode | ENABLE_EXTENDED_FLAGS | ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT) & ~ENABLE_QUICK_EDIT_MODE;
            if (SetConsoleMode(in_handle, new_in_mode) == .FALSE) {
                return error.FailedToSetConsoleMode;
            }
            errdefer _ = SetConsoleMode(in_handle, self.tty.old_in_mode);

            try hideCursor(&self.writer.interface);
            try enterAlt(&self.writer.interface);
            try clearStyle(&self.writer.interface);
            try self.writer.interface.flush();
        }

        fn cook(self: *Core) !void {
            try clearStyle(&self.writer.interface);
            try leaveAlt(&self.writer.interface);
            try showCursor(&self.writer.interface);
            try attributeReset(&self.writer.interface);
            try self.writer.interface.flush();

            const out_handle = std.Io.File.stdout().handle;
            _ = SetConsoleMode(out_handle, self.tty.old_out_mode);
            const in_handle = std.Io.File.stdin().handle;
            _ = SetConsoleMode(in_handle, self.tty.old_in_mode);
        }

        fn readKey(self: *Core, _: std.Io, blocking: bool) !?inp.Key {
            const timeout: std.os.windows.DWORD = if (blocking) INFINITE else 0;

            while (true) {
                const in_handle = std.Io.File.stdin().handle;
                var event_buffer: [1]INPUT_RECORD = undefined;
                var num_events_read: std.os.windows.DWORD = undefined;
                // exit early if there is no event ready to read
                waitForSingleObject(in_handle, timeout) catch |err| switch (err) {
                    error.WaitAbandoned => return null,
                    error.WaitTimeOut => return null,
                    error.Unexpected => |e| return e,
                };
                // read events from the buffer
                if (ReadConsoleInputW(in_handle, @ptrCast(&event_buffer), event_buffer.len, &num_events_read) == .FALSE) {
                    return error.FailedToReadConsoleInputW;
                }
                const event_type = event_buffer[0].EventType;
                const event = event_buffer[0].Event;
                switch (event_type) {
                    // KEY_EVENT
                    0x0001 => {
                        // ignore key up events
                        if (event.KeyEvent.bKeyDown == .FALSE) {
                            continue;
                        }
                        // if unicode char is not zero, return the codepoint
                        if (event.KeyEvent.uChar.UnicodeChar > 0) {
                            var utf8_buffer = [_]u8{0} ** 4;
                            const size = try std.unicode.utf16LeToUtf8(&utf8_buffer, &[_]u16{event.KeyEvent.uChar.UnicodeChar});
                            const cp = try std.unicode.utf8Decode(utf8_buffer[0..size]);
                            if (cp == 8 or cp == 127) return .backspace;
                            if (cp == 13 or cp == 10) return .enter;
                            if (cp == 9) return .tab;
                            if (cp == 0x1B) return .escape;
                            // remaining C0 control chars are ctrl+letter (0x01 == ctrl+a)
                            if (cp >= 0x01 and cp <= 0x1A) return .{ .ctrl = @intCast(cp - 0x01 + 'a') };
                            // alt+key — but not when a ctrl bit is also set,
                            // because AltGr reports as right alt + left ctrl
                            // and must keep producing plain codepoints
                            const alt_pressed = event.KeyEvent.dwControlKeyState & (0x0001 | 0x0002) != 0;
                            const ctrl_pressed = event.KeyEvent.dwControlKeyState & (0x0004 | 0x0008) != 0;
                            if (alt_pressed and !ctrl_pressed and cp >= 0x20 and cp < 0x7F) {
                                return .{ .alt = @intCast(cp) };
                            }
                            return .{ .codepoint = cp };
                        }
                        // otherwise it's a non-printable key. key codes are listed here:
                        // https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
                        else {
                            return switch (event.KeyEvent.wVirtualKeyCode) {
                                0x21 => .page_up,
                                0x22 => .page_down,
                                0x23 => .end,
                                0x24 => .home,
                                0x25 => .arrow_left,
                                0x26 => .arrow_up,
                                0x27 => .arrow_right,
                                0x28 => .arrow_down,
                                0x0D => .enter,
                                0x2D => .insert,
                                0x2E => .delete,
                                // F1-F12
                                0x70...0x7B => .{ .f = @intCast(event.KeyEvent.wVirtualKeyCode - 0x70 + 1) },
                                else => continue,
                            };
                        }
                    },
                    // MOUSE_EVENT
                    0x0002 => {
                        const mouse_event = event.MouseEvent;
                        const raw_x = mouse_event.dwMousePosition.X;
                        const raw_y = mouse_event.dwMousePosition.Y;
                        if (raw_x < 0 or raw_y < 0) continue;
                        const x: usize = @intCast(raw_x);
                        const y: usize = @intCast(raw_y);
                        const ctrl_pressed = mouse_event.dwControlKeyState & (0x0004 | 0x0008) != 0;

                        const MOUSE_MOVED: std.os.windows.DWORD = 0x0001;
                        const MOUSE_WHEELED: std.os.windows.DWORD = 0x0004;

                        if (mouse_event.dwEventFlags & MOUSE_WHEELED != 0) {
                            // high word of dwButtonState is a signed scroll
                            // delta — positive means away from the user (up)
                            const delta: i16 = @bitCast(@as(u16, @truncate(mouse_event.dwButtonState >> 16)));
                            return .{ .mouse = .{
                                .x = x,
                                .y = y,
                                .action = .{ .scroll = if (delta > 0) .up else .down },
                                .ctrl = ctrl_pressed,
                            } };
                        }

                        // ignore pure-motion events (no button state change)
                        if (mouse_event.dwEventFlags & MOUSE_MOVED != 0) {
                            self.last_mouse_buttons = mouse_event.dwButtonState;
                            continue;
                        }

                        // detect press/release by diffing button bitmask
                        const buttons = mouse_event.dwButtonState;
                        const pressed = buttons & ~self.last_mouse_buttons;
                        const released = self.last_mouse_buttons & ~buttons;
                        self.last_mouse_buttons = buttons;

                        const FROM_LEFT_1ST: std.os.windows.DWORD = 0x0001;
                        const RIGHTMOST: std.os.windows.DWORD = 0x0002;
                        const FROM_LEFT_2ND: std.os.windows.DWORD = 0x0004;

                        const press_button: ?inp.MouseButton =
                            if (pressed & FROM_LEFT_1ST != 0) .left else if (pressed & FROM_LEFT_2ND != 0) .middle else if (pressed & RIGHTMOST != 0) .right else null;
                        if (press_button) |b| {
                            return .{ .mouse = .{ .x = x, .y = y, .action = .{ .press = b }, .ctrl = ctrl_pressed } };
                        }

                        const release_button: ?inp.MouseButton =
                            if (released & FROM_LEFT_1ST != 0) .left else if (released & FROM_LEFT_2ND != 0) .middle else if (released & RIGHTMOST != 0) .right else null;
                        if (release_button) |b| {
                            return .{ .mouse = .{ .x = x, .y = y, .action = .{ .release = b }, .ctrl = ctrl_pressed } };
                        }

                        continue;
                    },
                    // WINDOW_BUFFER_SIZE_EVENT
                    0x0004 => return .{ .event = .resize },
                    // MENU_EVENT
                    0x0008 => {},
                    // FOCUS_EVENT
                    0x0010 => {},
                    else => return error.UnrecognizedEventType,
                }
            }
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
            self.raw.oflag = .{ .OPOST = true };
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
                    error.EndOfStream => return null,
                    else => |e| return e,
                };
                if (size == 0) return null;

                try self.parser.queueBytes(buffer[0..size]);
                // the tty hands us a whole sequence in one read, so an ESC
                // still pending was the escape key, not a split sequence
                try self.parser.flushEscape();
                return self.parser.popQueued();
            }
        }
    },
};

pub const Terminal = struct {
    core: Core,
    size: Size,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !Terminal {
        switch (builtin.os.tag) {
            .windows => {
                const tty = Core.Tty{
                    .old_out_mode = undefined,
                    .old_in_mode = undefined,
                };

                const write_buffer = try allocator.alloc(u8, write_buffer_size);
                errdefer allocator.free(write_buffer);

                var self = Terminal{
                    .core = .{
                        .tty = tty,
                        .write_buffer = write_buffer,
                        .writer = tty.writer(write_buffer),
                        .allocator = allocator,
                        .last_mouse_buttons = 0,
                    },
                    .size = .{ .width = 0, .height = 0 },
                };

                try self.core.uncook();
                errdefer self.core.cook() catch {};

                const handler = struct {
                    fn run(fdw_ctrl_type: std.os.windows.DWORD) callconv(.c) std.os.windows.BOOL {
                        const CTRL_C_EVENT: std.os.windows.DWORD = 0;

                        switch (fdw_ctrl_type) {
                            CTRL_C_EVENT => {
                                quit.store(true, .monotonic);
                                return .TRUE;
                            },
                            else => {},
                        }
                        return .FALSE;
                    }
                }.run;
                try Core.setConsoleCtrlHandler(handler, true);

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
        switch (builtin.os.tag) {
            .windows => {
                self.core.cook() catch {};
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

    pub fn render(self: *Terminal, root_widget: anytype, last_grid: *grd.Grid, last_size: *Size) !bool {
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
            self.core.allocator,
            root_widget,
            last_grid,
            last_size,
            self.size,
        );
    }
};

pub fn renderToWriter(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    root_widget: anytype,
    last_grid: *grd.Grid,
    last_size: *Size,
    size: Size,
) !bool {
    if (size.width == 0 or size.height == 0) {
        return false;
    }

    // determine if the grid must be refreshed
    var force_refresh = false;
    if (last_size.*.width != size.width or last_size.*.height != size.height) {
        force_refresh = true;
    } else if (root_widget.getGrid()) |grid| {
        if (last_grid.size.width != grid.size.width or last_grid.size.height != grid.size.height) {
            force_refresh = true;
        }
    }

    var grid_changed = force_refresh;

    // start escape code for synchronized output
    // everything in between the start and stop code is printed at once to prevent flickering
    try writer.writeAll("\x1B[?2026h");

    if (force_refresh) {
        // rebuild the root widget
        try root_widget.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = size.width, .height = size.height },
        }, root_widget.getFocus());
        try clearRect(writer, 0, 0, size);
        last_size.* = size;

        // render the grid
        if (root_widget.getGrid()) |grid| {
            last_grid.deinit();
            last_grid.* = try grd.Grid.initFromGridOwned(allocator, grid, grid.size, 0, 0);
            for (0..grid.size.height) |y| {
                for (0..grid.size.width) |x| {
                    const cell = grid.cells.items[try grid.cells.at(.{ y, x })];
                    if (cell.rune) |rune| {
                        try writeAt(writer, rune, cell.style, x, y, size.height);
                    }
                }
            }
        }
    } else {
        if (root_widget.getGrid()) |grid| {
            // clear cells that are in last grid but not current grid
            for (0..last_grid.size.height) |y| {
                for (0..last_grid.size.width) |x| {
                    const cell = grid.cells.items[try grid.cells.at(.{ y, x })];
                    // a continuation column is occupied by the wide rune to
                    // its left, not empty — clearing it would chop the glyph
                    if (cell.rune == null and !cell.continuation) {
                        try writeAt(writer, " ", .{}, x, y, size.height);
                    }

                    if (!grid_changed) {
                        const last_cell = last_grid.cells.items[try last_grid.cells.at(.{ y, x })];
                        grid_changed = !cell.eql(last_cell);
                    }
                }
            }

            // render the grid
            for (0..grid.size.height) |y| {
                for (0..grid.size.width) |x| {
                    const cell = grid.cells.items[try grid.cells.at(.{ y, x })];
                    if (cell.rune) |rune| {
                        try writeAt(writer, rune, cell.style, x, y, size.height);
                    }
                }
            }

            // update last_grid if necessary
            if (grid_changed) {
                last_grid.deinit();
                last_grid.* = try grd.Grid.initFromGridOwned(allocator, grid, grid.size, 0, 0);
            }
        }
    }

    // stop escape code for synchronized output
    try writer.writeAll("\x1B[?2026l");
    try writer.flush();

    return grid_changed;
}

fn writeAt(writer: *std.Io.Writer, txt: []const u8, style: grd.Grid.Style, x: usize, y: usize, height: usize) !void {
    if (y >= height) return;
    try moveCursor(writer, x, y);
    // each cell re-establishes its own style, so a single reset afterward is
    // enough to keep it from bleeding into the next cell we move to.
    var styled = false;
    if (style.inverted) {
        try writer.writeAll("\x1B[7m");
        styled = true;
    }
    if (style.fg) |c| {
        try writer.print("\x1B[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
        styled = true;
    }
    if (style.bg) |c| {
        try writer.print("\x1B[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
        styled = true;
    }
    try writer.writeAll(txt);
    if (styled) try writer.writeAll("\x1B[0m");
}

pub fn moveCursor(writer: *std.Io.Writer, x: usize, y: usize) !void {
    _ = try writer.print("\x1B[{};{}H", .{ y + 1, x + 1 });
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
    esc_buffer: std.ArrayList(u8),
    key_queue: std.DoublyLinkedList,
    // the buffered sequence outgrew esc_buffer. its remaining bytes are still
    // consumed up to the terminator, then it reports as one unknown key.
    esc_overflowed: bool,

    // fits the reports terminals send unprompted (device attributes, cursor
    // position, mode queries); anything longer is swallowed, not parsed.
    const esc_buffer_size = 128;

    const KeyAndNode = struct {
        key: inp.Key,
        node: std.DoublyLinkedList.Node,
    };

    pub fn init(allocator: std.mem.Allocator) !EscapeParser {
        return .{
            .allocator = allocator,
            .esc_buffer = try std.ArrayList(u8).initCapacity(allocator, esc_buffer_size),
            .key_queue = std.DoublyLinkedList{},
            .esc_overflowed = false,
        };
    }

    pub fn deinit(self: *EscapeParser) void {
        self.esc_buffer.deinit(self.allocator);
        while (self.key_queue.popFirst()) |node| {
            const key_and_node: *KeyAndNode = @fieldParentPtr("node", node);
            self.allocator.destroy(key_and_node);
        }
    }

    pub fn popQueued(self: *EscapeParser) ?inp.Key {
        const node = self.key_queue.popFirst() orelse return null;
        const key_and_node: *KeyAndNode = @fieldParentPtr("node", node);
        const key = key_and_node.key;
        self.allocator.destroy(key_and_node);
        return key;
    }

    fn append(self: *EscapeParser, key: inp.Key) !void {
        const key_and_node = try self.allocator.create(KeyAndNode);
        key_and_node.* = .{ .key = key, .node = .{} };
        self.key_queue.append(&key_and_node.node);
    }

    // drop a partially-buffered escape sequence without reporting anything
    pub fn clearScratch(self: *EscapeParser) void {
        self.esc_buffer.clearRetainingCapacity();
        self.esc_overflowed = false;
    }

    // decode `bytes` and queue every key they yield, in arrival order. a
    // sequence cut off at the end stays buffered until the rest arrives, so
    // input may be fed in arbitrary chunks.
    pub fn queueBytes(self: *EscapeParser, bytes: []const u8) !void {
        const text = std.unicode.Utf8View.init(bytes) catch return;
        var iter = text.iterator();
        while (iter.nextCodepoint()) |codepoint| {
            try self.writeCodepoint(codepoint);
        }
    }

    // report a held-back ESC as the escape key. an ESC is buffered rather than
    // reported at once because it may open a CSI/SS3 sequence or an alt combo;
    // a caller that knows nothing more is coming resolves it with this. a
    // longer partial sequence is unaffected, since it may still complete.
    pub fn flushEscape(self: *EscapeParser) !void {
        if (self.esc_buffer.items.len == 1 and self.esc_buffer.items[0] == '\x1B') {
            self.clearScratch();
            try self.append(.escape);
        }
    }

    // give up on the buffered sequence: a lone ESC was the escape key, and a
    // longer fragment is unparseable and reports as a single unknown key.
    fn abortSequence(self: *EscapeParser) !void {
        const lone_esc = self.esc_buffer.items.len == 1;
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
        if (self.esc_buffer.items.len == 0) {
            // hold the ESC back: the next byte decides whether it opens a
            // sequence, completes an alt combo, or was the escape key
            if (codepoint == '\x1B') {
                self.esc_buffer.appendAssumeCapacity('\x1B');
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

        // the byte after ESC either opens a CSI/SS3 sequence or completes an
        // alt combo; anything non-printable means the ESC was the escape key
        if (self.esc_buffer.items.len == 1) {
            if (byte == '[' or byte == 'O') {
                self.esc_buffer.appendAssumeCapacity(byte);
                return;
            }
            self.clearScratch();
            if (byte >= 0x20 and byte < 0x7F) return self.append(.{ .alt = byte });
            try self.append(.escape);
            // a second ESC opens the next sequence rather than decoding here
            if (byte == '\x1B') {
                self.esc_buffer.appendAssumeCapacity('\x1B');
                return;
            }
            return self.append(plainKey(codepoint));
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
                    'M', 'm' => parseSgrMouse(self.esc_buffer.items, byte == 'M') orelse .unknown,
                    '~' => blk: {
                        var codes = std.mem.splitSequence(u8, self.esc_buffer.items[2..], ";");
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
            else => if (self.esc_buffer.items.len == self.esc_buffer.capacity) {
                self.esc_overflowed = true;
            } else {
                self.esc_buffer.appendAssumeCapacity(byte);
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
