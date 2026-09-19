const std = @import("std");
const posix = std.posix;

pub var global_term_ptr: ?*Term = null;

pub fn sigintHandler(_: posix.SIG) callconv(.c) void {
    if (global_term_ptr) |t| t.deinit();
    std.process.exit(130);
}

pub fn sigtermHandler(_: posix.SIG) callconv(.c) void {
    if (global_term_ptr) |t| t.deinit();
    std.process.exit(143);
}

pub fn writeAll(fd: posix.fd_t, bytes: []const u8) void {
    var total: usize = 0;
    while (total < bytes.len) {
        const rc = posix.system.write(fd, bytes.ptr + total, bytes.len - total);
        if (posix.errno(rc) != .SUCCESS or rc == 0) break;
        total += @intCast(rc);
    }
}

pub const Term = struct {
    orig_termios: posix.termios,
    raw_active: bool = false,
    tty_fd: posix.fd_t,
    owns_fd: bool = false,
    in_buf: [512]u8 = undefined,
    in_head: usize = 0,
    in_tail: usize = 0,

    pub fn init() !Term {
        const rc = posix.system.open("/dev/tty", posix.system.O{ .ACCMODE = .RDWR }, 0);
        var fd: posix.fd_t = posix.STDIN_FILENO;
        var owns = false;
        if (posix.errno(rc) == .SUCCESS) {
            fd = @intCast(rc);
            owns = true;
        }
        return Term{
            .orig_termios = try posix.tcgetattr(fd),
            .raw_active = false,
            .tty_fd = fd,
            .owns_fd = owns,
        };
    }

    pub fn deinit(self: *Term) void {
        self.disableRaw();
        writeAll(self.tty_fd, "\x1b[?2004l\x1b[?25h");
        if (self.owns_fd) {
            _ = posix.system.close(self.tty_fd);
            self.owns_fd = false;
        }
    }

    pub fn enableRaw(self: *Term) !void {
        if (self.raw_active) return;
        var raw = self.orig_termios;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = true;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(self.tty_fd, .FLUSH, raw);
        self.raw_active = true;
        self.in_head = 0;
        self.in_tail = 0;
        writeAll(self.tty_fd, "\x1b[?2004h");
    }

    pub fn disableRaw(self: *Term) void {
        if (!self.raw_active) return;
        writeAll(self.tty_fd, "\x1b[?2004l\x1b[?25h");
        posix.tcsetattr(self.tty_fd, .FLUSH, self.orig_termios) catch {};
        self.raw_active = false;
    }

    pub fn suspendRaw(self: *Term) void {
        writeAll(self.tty_fd, "\r\x1b[2K");
        self.disableRaw();
    }

    pub fn resumeRaw(self: *Term) !void {
        try self.enableRaw();
    }

    pub fn getWindowSize(self: *const Term) struct { rows: u16, cols: u16 } {
        var ws: posix.winsize = undefined;
        const rc = posix.system.ioctl(self.tty_fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        return if (rc == 0 and ws.col > 0) .{ .rows = ws.row, .cols = ws.col } else .{ .rows = 24, .cols = 80 };
    }

    pub fn readByte(self: *Term, timeout_ms: i32) ?u8 {
        if (self.in_head < self.in_tail) {
            const b = self.in_buf[self.in_head];
            self.in_head += 1;
            return b;
        }

        self.in_head = 0;
        self.in_tail = 0;

        if (timeout_ms >= 0) {
            var pfd = [1]posix.pollfd{.{ .fd = self.tty_fd, .events = posix.POLL.IN, .revents = 0 }};
            if ((posix.poll(&pfd, timeout_ms) catch return null) <= 0) return null;
        }

        const n = posix.read(self.tty_fd, &self.in_buf) catch return null;
        if (n == 0) return null;
        self.in_tail = n;
        self.in_head = 1;
        return self.in_buf[0];
    }

    pub fn hasPendingInput(self: *const Term) bool {
        if (self.in_head < self.in_tail) return true;
        var pfd = [1]posix.pollfd{.{ .fd = self.tty_fd, .events = posix.POLL.IN, .revents = 0 }};
        const rc = posix.poll(&pfd, 0) catch return false;
        return rc > 0;
    }
};

test "Term hasPendingInput" {
    const term = try Term.init();
    defer @constCast(&term).deinit();
    _ = term.hasPendingInput();
}

