const std = @import("std");
const posix = std.posix;
const terminal = @import("terminal.zig");
const Term = terminal.Term;
const completion = @import("completion.zig");
const history_expansion = @import("history_expansion.zig");
const render = @import("render.zig");

pub fn ArrayList(comptime T: type) type {
    return std.array_list.AlignedManaged(T, null);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ?[]u8 {
    var path_z: [4096:0]u8 = undefined;
    const pz = completion.toCStr(&path_z, path) orelse return null;
    const fd = posix.system.open(pz.ptr, posix.system.O{ .ACCMODE = .RDONLY }, 0);
    if (posix.errno(fd) != .SUCCESS) return null;
    defer _ = posix.system.close(@intCast(fd));

    var list = ArrayList(u8).init(allocator);
    defer list.deinit();

    var chunk: [4096]u8 = undefined;
    while (list.items.len < max_size) {
        const to_read = @min(chunk.len, max_size - list.items.len);
        const rc = posix.system.read(@intCast(fd), &chunk, to_read);
        if (posix.errno(rc) != .SUCCESS or rc == 0) break;
        list.appendSlice(chunk[0..@intCast(rc)]) catch break;
    }
    return list.toOwnedSlice() catch null;
}

pub fn writeFile(path: []const u8, content: []const u8) !void {
    var path_z: [4096:0]u8 = undefined;
    const pz = completion.toCStr(&path_z, path) orelse return error.PathTooLong;
    const fd = posix.system.open(pz.ptr, posix.system.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (posix.errno(fd) != .SUCCESS) return error.OpenFailed;
    defer _ = posix.system.close(@intCast(fd));

    var total: usize = 0;
    while (total < content.len) {
        const rc = posix.system.write(@intCast(fd), content.ptr + total, content.len - total);
        if (posix.errno(rc) != .SUCCESS or rc == 0) return error.WriteFailed;
        total += @intCast(rc);
    }
}

pub fn deleteFile(path: []const u8) void {
    var path_z: [4096:0]u8 = undefined;
    if (completion.toCStr(&path_z, path)) |pz| _ = posix.system.unlink(pz.ptr);
}

pub const CompletionCache = struct {
    allocator: std.mem.Allocator,
    prefix: ?[]u8 = null,
    candidates: ArrayList([]const u8),
    empty_token: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) CompletionCache {
        return .{
            .allocator = allocator,
            .prefix = null,
            .candidates = ArrayList([]const u8).init(allocator),
            .empty_token = null,
        };
    }

    pub fn deinit(self: *CompletionCache) void {
        self.clear();
        self.candidates.deinit();
    }

    pub fn clear(self: *CompletionCache) void {
        if (self.prefix) |p| {
            self.allocator.free(p);
            self.prefix = null;
        }
        if (self.empty_token) |t| {
            self.allocator.free(t);
            self.empty_token = null;
        }
        for (self.candidates.items) |c| self.allocator.free(c);
        self.candidates.clearRetainingCapacity();
    }
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    term: *const Term,
    prompt_prefix: []const u8,
    prompt_last_line: []const u8,
    prompt_vis_w: usize = 0,
    first_render: bool = true,
    rendered_cursor_row: usize = 0,
    rendered_total_rows: usize = 0,
    buffer: ArrayList(u8),
    cursor_pos: usize = 0,
    history: ArrayList([]const u8),
    hist_index: ?usize = null,
    saved_input: ArrayList(u8),
    ghost_suggestion: ?[]const u8 = null,
    ghost_buf: ArrayList(u8),
    command_cache: completion.CommandCache,
    completion_cache: CompletionCache,

    in_completion: bool = false,
    candidates: ArrayList([]const u8),
    selected_candidate: usize = 0,
    comp_start_byte: usize = 0,
    max_candidate_width: usize = 0,
    rendered_menu_rows: usize = 0,
    in_paste: bool = false,
    in_isearch: bool = false,
    isearch_query: ArrayList(u8),
    isearch_match_index: ?usize = null,
    render_buf: ArrayList(u8),
    yank_index: usize = 0,
    yank_len: usize = 0,
    last_was_yank: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, term: *const Term, prompt: []const u8) Editor {
        var prefix: []const u8 = "";
        var last: []const u8 = prompt;
        if (std.mem.lastIndexOfScalar(u8, prompt, '\n')) |idx| {
            prefix = prompt[0 .. idx + 1];
            last = prompt[idx + 1 ..];
        }
        var ed = Editor{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .term = term,
            .prompt_prefix = prefix,
            .prompt_last_line = last,
            .prompt_vis_w = render.getVisibleWidth(last),
            .buffer = ArrayList(u8).init(allocator),
            .history = ArrayList([]const u8).init(allocator),
            .saved_input = ArrayList(u8).init(allocator),
            .candidates = ArrayList([]const u8).init(allocator),
            .isearch_query = ArrayList(u8).init(allocator),
            .render_buf = ArrayList(u8).init(allocator),
            .command_cache = completion.CommandCache.init(allocator),
            .completion_cache = CompletionCache.init(allocator),
            .ghost_buf = ArrayList(u8).init(allocator),
        };
        ed.buffer.ensureTotalCapacity(256) catch {};
        ed.history.ensureTotalCapacity(2048) catch {};
        ed.render_buf.ensureTotalCapacity(4096) catch {};
        ed.ghost_buf.ensureTotalCapacity(256) catch {};
        ed.candidates.ensureTotalCapacity(128) catch {};
        ed.command_cache.load(environ);
        return ed;
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit();
        for (self.history.items) |item| self.allocator.free(item);
        self.history.deinit();
        self.saved_input.deinit();
        self.clearCandidates();
        self.candidates.deinit();
        self.isearch_query.deinit();
        self.render_buf.deinit();
        self.command_cache.deinit();
        self.completion_cache.deinit();
        self.ghost_buf.deinit();
    }

    pub fn loadHistoryFromFile(self: *Editor, path: []const u8) void {
        const content = readFileAlloc(self.allocator, path, 2 * 1024 * 1024) orelse return;
        defer self.allocator.free(content);

        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        var pos: usize = content.len;
        var count: usize = 0;

        while (pos > 0 and count < 2000) {
            var line_end = pos;
            while (line_end > 0 and (content[line_end - 1] == '\n' or content[line_end - 1] == '\r')) : (line_end -= 1) {}
            if (line_end == 0) break;

            var line_start = line_end;
            while (line_start > 0 and content[line_start - 1] != '\n' and content[line_start - 1] != '\r') : (line_start -= 1) {}
            pos = line_start;

            var trimmed = std.mem.trim(u8, content[line_start..line_end], " \t\r\n");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (trimmed[0] >= '0' and trimmed[0] <= '9') {
                var idx: usize = 0;
                while (idx < trimmed.len and (trimmed[idx] >= '0' and trimmed[idx] <= '9')) : (idx += 1) {}
                if (idx < trimmed.len and (trimmed[idx] == ' ' or trimmed[idx] == '\t')) {
                    while (idx < trimmed.len and (trimmed[idx] == ' ' or trimmed[idx] == '\t')) : (idx += 1) {}
                    trimmed = trimmed[idx..];
                }
            }
            if (trimmed.len == 0) continue;

            if (!seen.contains(trimmed)) {
                const dup = self.allocator.dupe(u8, trimmed) catch continue;
                seen.put(trimmed, {}) catch {
                    self.allocator.free(dup);
                    continue;
                };
                self.history.append(dup) catch {
                    self.allocator.free(dup);
                    continue;
                };
                count += 1;
            }
        }
    }

    pub fn updateGhost(self: *Editor) void {
        self.ghost_suggestion = null;
        self.ghost_buf.clearRetainingCapacity();
        if (self.in_completion or self.in_paste or self.in_isearch) return;
        if (self.cursor_pos != self.buffer.items.len or self.buffer.items.len == 0) return;

        const input = self.buffer.items;

        if (self.history.items.len > 0 and (input[0] == '^' or std.mem.indexOfScalar(u8, input, '!') != null)) {
            const exp_res = history_expansion.expandHistory(self.allocator, input, self.history.items, "") catch null;
            if (exp_res) |res| {
                defer self.allocator.free(res.expanded);
                if (res.did_expand and res.err_msg == null and !std.mem.eql(u8, res.expanded, input)) {
                    if (res.expanded.len > input.len and std.mem.startsWith(u8, res.expanded, input)) {
                        self.ghost_buf.appendSlice(res.expanded[input.len..]) catch return;
                        self.ghost_suggestion = self.ghost_buf.items;
                        return;
                    }
                }
            }
        }

        for (self.history.items) |h| {
            if (std.mem.startsWith(u8, h, input) and h.len > input.len) {
                self.ghost_suggestion = h[input.len..];
                return;
            }
        }

        const pos_info = completion.getCommandPositionInfo(input);
        if (pos_info.is_command_position and pos_info.prefix.len > 0) {
            if (std.mem.indexOfScalar(u8, pos_info.prefix, '/') != null or std.mem.startsWith(u8, pos_info.prefix, "~")) {
                var path_buf: [512]u8 = undefined;
                if (completion.findPathMatch(self.environ, pos_info.prefix, &path_buf)) |sugg| {
                    self.ghost_buf.appendSlice(sugg) catch return;
                    self.ghost_suggestion = self.ghost_buf.items;
                    return;
                }
            } else {
                if (self.command_cache.findMatch(pos_info.prefix)) |full_cmd| {
                    if (full_cmd.len > pos_info.prefix.len) {
                        self.ghost_buf.appendSlice(full_cmd[pos_info.prefix.len..]) catch return;
                        self.ghost_suggestion = self.ghost_buf.items;
                        return;
                    }
                }
            }
        }

        var arg_buf: [512]u8 = undefined;
        if (completion.findArgumentPathMatch(self.environ, input, &arg_buf)) |sugg| {
            self.ghost_buf.appendSlice(sugg) catch return;
            self.ghost_suggestion = self.ghost_buf.items;
            return;
        }

        // Fast in-memory environment variable matching
        const start = completion.findCompletionStart(input, self.cursor_pos);
        const token = input[start..self.cursor_pos];
        if (token.len > 0 and token[0] == '$') {
            const var_prefix = token[1..];
            const COMMON_ENV_VARS = [_][]const u8{
                "HOME", "PATH", "USER", "SHELL", "TERM", "PWD", "EDITOR", "VISUAL", "LANG", "LC_ALL", "TMPDIR", "HOSTNAME", "LOGNAME", "SHLVL", "HISTFILE",
            };
            for (COMMON_ENV_VARS) |var_name| {
                if (std.mem.startsWith(u8, var_name, var_prefix) and var_name.len > var_prefix.len) {
                    if (completion.getEnv(self.environ, var_name) != null) {
                        self.ghost_buf.appendSlice(var_name[var_prefix.len..]) catch return;
                        self.ghost_suggestion = self.ghost_buf.items;
                        return;
                    }
                }
            }
        }

        // If the terminal has pending keystrokes ready to read, skip expensive completion queries.
        if (self.term.hasPendingInput()) return;

        const comp_prefix = input[0..start];

        // Check if completion_cache matches current command prefix
        if (self.completion_cache.prefix) |cached_prefix| {
            if (std.mem.eql(u8, cached_prefix, comp_prefix)) {
                if (self.completion_cache.empty_token) |et| {
                    if (std.mem.startsWith(u8, token, et)) return;
                }
                for (self.completion_cache.candidates.items) |cand| {
                    const clean_cand = std.mem.trimEnd(u8, cand, " ");
                    if (std.mem.startsWith(u8, clean_cand, token) and clean_cand.len > token.len) {
                        self.ghost_buf.appendSlice(clean_cand[token.len..]) catch return;
                        self.ghost_suggestion = self.ghost_buf.items;
                        return;
                    }
                }
                return;
            }
        }

        // Cache miss: query completions and update cache
        self.completion_cache.clear();
        self.completion_cache.prefix = self.allocator.dupe(u8, comp_prefix) catch null;

        completion.collectCompletionsWithEnv(
            self.allocator,
            self.io,
            self.environ,
            &self.command_cache,
            &self.completion_cache.candidates,
            input,
            self.cursor_pos,
        );

        if (self.completion_cache.candidates.items.len == 0) {
            self.completion_cache.empty_token = self.allocator.dupe(u8, token) catch null;
            return;
        }

        for (self.completion_cache.candidates.items) |cand| {
            const clean_cand = std.mem.trimEnd(u8, cand, " ");
            if (std.mem.startsWith(u8, clean_cand, token) and clean_cand.len > token.len) {
                self.ghost_buf.appendSlice(clean_cand[token.len..]) catch return;
                self.ghost_suggestion = self.ghost_buf.items;
                return;
            }
        }
    }

    pub fn clearCandidates(self: *Editor) void {
        for (self.candidates.items) |c| self.allocator.free(c);
        self.candidates.clearRetainingCapacity();
        self.max_candidate_width = 0;
    }

    pub fn collectCompletions(self: *Editor) void {
        self.clearCandidates();
        self.comp_start_byte = completion.findCompletionStart(self.buffer.items, self.cursor_pos);
        const comp_prefix = self.buffer.items[0..self.comp_start_byte];
        const token = self.buffer.items[self.comp_start_byte..self.cursor_pos];

        if (self.completion_cache.prefix) |cached_prefix| {
            if (std.mem.eql(u8, cached_prefix, comp_prefix) and self.completion_cache.candidates.items.len > 0) {
                for (self.completion_cache.candidates.items) |cand| {
                    if (token.len == 0 or std.mem.startsWith(u8, cand, token)) {
                        completion.addCandidate(self.allocator, &self.candidates, cand);
                    }
                }
                if (self.candidates.items.len > 0) {
                    self.max_candidate_width = render.getMaxCandidateWidth(self.candidates.items);
                    return;
                }
            }
        }

        self.completion_cache.clear();
        self.completion_cache.prefix = self.allocator.dupe(u8, comp_prefix) catch null;

        completion.collectCompletionsWithEnv(
            self.allocator,
            self.io,
            self.environ,
            &self.command_cache,
            &self.candidates,
            self.buffer.items,
            self.cursor_pos,
        );

        for (self.candidates.items) |cand| {
            completion.addCandidate(self.allocator, &self.completion_cache.candidates, cand);
        }

        self.max_candidate_width = render.getMaxCandidateWidth(self.candidates.items);
    }

    pub fn insertChar(self: *Editor, cp: u21) !void {
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch return;
        try self.buffer.insertSlice(self.cursor_pos, utf8_buf[0..len]);
        self.cursor_pos += len;
    }

    pub fn insertSlice(self: *Editor, bytes: []const u8) !void {
        try self.buffer.insertSlice(self.cursor_pos, bytes);
        self.cursor_pos += bytes.len;
    }

    fn utf8StepBack(self: *const Editor, from: usize) usize {
        if (from == 0) return 0;
        var step: usize = 1;
        while (from >= step and (self.buffer.items[from - step] & 0xC0) == 0x80) step += 1;
        return step;
    }

    fn utf8StepForward(self: *const Editor, from: usize) usize {
        if (from >= self.buffer.items.len) return 0;
        var step: usize = 1;
        while (from + step < self.buffer.items.len and (self.buffer.items[from + step] & 0xC0) == 0x80) step += 1;
        return step;
    }

    pub fn deleteRange(self: *Editor, start: usize, len: usize) void {
        if (len == 0 or start >= self.buffer.items.len) return;
        const actual_len = @min(len, self.buffer.items.len - start);
        const tail_start = start + actual_len;
        const tail_len = self.buffer.items.len - tail_start;
        if (tail_len > 0) {
            std.mem.copyForwards(u8, self.buffer.items[start .. start + tail_len], self.buffer.items[tail_start .. tail_start + tail_len]);
        }
        self.buffer.shrinkRetainingCapacity(self.buffer.items.len - actual_len);
    }

    pub fn deleteBackward(self: *Editor) void {
        const step = self.utf8StepBack(self.cursor_pos);
        if (step == 0) return;
        const start = self.cursor_pos - step;
        self.deleteRange(start, step);
        self.cursor_pos = start;
    }

    pub fn deleteForward(self: *Editor) void {
        const step = self.utf8StepForward(self.cursor_pos);
        if (step == 0) return;
        self.deleteRange(self.cursor_pos, step);
    }

    pub fn killWordBackward(self: *Editor) void {
        if (self.cursor_pos == 0) return;
        var p = self.cursor_pos;
        while (p > 0 and (self.buffer.items[p - 1] == ' ' or self.buffer.items[p - 1] == '\t')) : (p -= 1) {}
        while (p > 0 and self.buffer.items[p - 1] != ' ' and self.buffer.items[p - 1] != '\t') : (p -= 1) {}
        const count = self.cursor_pos - p;
        self.deleteRange(p, count);
        self.cursor_pos = p;
    }

    pub fn killLineToEnd(self: *Editor) void {
        self.buffer.shrinkRetainingCapacity(self.cursor_pos);
    }

    pub fn killLineToStart(self: *Editor) void {
        if (self.cursor_pos == 0) return;
        self.deleteRange(0, self.cursor_pos);
        self.cursor_pos = 0;
    }

    pub fn killWordForward(self: *Editor) void {
        if (self.cursor_pos >= self.buffer.items.len) return;
        var p = self.cursor_pos;
        while (p < self.buffer.items.len and (self.buffer.items[p] == ' ' or self.buffer.items[p] == '\t')) : (p += 1) {}
        while (p < self.buffer.items.len and self.buffer.items[p] != ' ' and self.buffer.items[p] != '\t') : (p += 1) {}
        self.deleteRange(self.cursor_pos, p - self.cursor_pos);
    }

    pub fn clearLine(self: *Editor) void {
        self.buffer.clearRetainingCapacity();
        self.cursor_pos = 0;
    }

    pub fn moveCursorLeft(self: *Editor) void {
        self.cursor_pos -= self.utf8StepBack(self.cursor_pos);
    }

    pub fn yankLastArg(self: *Editor) void {
        if (self.history.items.len == 0) return;
        const target_idx = (if (self.last_was_yank) self.yank_index else 0) % self.history.items.len;

        if (history_expansion.getLastArg(self.allocator, self.history.items[target_idx]) catch null) |arg| {
            defer self.allocator.free(arg);
            if (self.last_was_yank and self.yank_len > 0) {
                const start = self.cursor_pos - self.yank_len;
                self.deleteRange(start, self.yank_len);
                self.cursor_pos = start;
            }
            self.insertSlice(arg) catch return;
            self.yank_len = arg.len;
            self.yank_index = target_idx + 1;
            self.last_was_yank = true;
        }
    }

    pub fn expandHistoryLine(self: *Editor) bool {
        if (self.history.items.len == 0) return false;
        const res = history_expansion.expandHistory(self.allocator, self.buffer.items, self.history.items, "") catch return false;
        defer self.allocator.free(res.expanded);

        if (res.did_expand and res.err_msg == null and !std.mem.eql(u8, res.expanded, self.buffer.items)) {
            self.buffer.clearRetainingCapacity();
            self.buffer.appendSlice(res.expanded) catch return false;
            self.cursor_pos = self.buffer.items.len;
            return true;
        }
        return false;
    }

    pub fn acceptGhost(self: *Editor) void {
        if (self.expandHistoryLine()) {
            self.ghost_suggestion = null;
            return;
        }
        if (self.ghost_suggestion) |sugg| {
            self.buffer.appendSlice(sugg) catch return;
            self.cursor_pos = self.buffer.items.len;
            self.ghost_suggestion = null;
        }
    }

    pub fn moveCursorRight(self: *Editor) void {
        if (self.cursor_pos < self.buffer.items.len) {
            self.cursor_pos += self.utf8StepForward(self.cursor_pos);
        } else {
            self.acceptGhost();
        }
    }

    pub fn moveCursorEnd(self: *Editor) void {
        if (self.cursor_pos < self.buffer.items.len) {
            self.cursor_pos = self.buffer.items.len;
        } else {
            self.acceptGhost();
        }
    }

    pub fn moveWordForward(self: *Editor) void {
        if (self.cursor_pos < self.buffer.items.len) {
            var p = self.cursor_pos;
            while (p < self.buffer.items.len and (self.buffer.items[p] == ' ' or self.buffer.items[p] == '\t')) : (p += 1) {}
            while (p < self.buffer.items.len and self.buffer.items[p] != ' ' and self.buffer.items[p] != '\t') : (p += 1) {}
            self.cursor_pos = p;
        } else if (self.ghost_suggestion) |sugg| {
            var end: usize = 0;
            while (end < sugg.len and (sugg[end] == ' ' or sugg[end] == '\t')) : (end += 1) {}
            while (end < sugg.len and sugg[end] != ' ' and sugg[end] != '\t') : (end += 1) {}
            while (end < sugg.len and (sugg[end] == ' ' or sugg[end] == '\t')) : (end += 1) {}
            if (end == 0) end = sugg.len;
            self.buffer.appendSlice(sugg[0..end]) catch return;
            self.cursor_pos = self.buffer.items.len;
        }
    }

    pub fn moveWordBackward(self: *Editor) void {
        if (self.cursor_pos == 0) return;
        var p = self.cursor_pos;
        while (p > 0 and (self.buffer.items[p - 1] == ' ' or self.buffer.items[p - 1] == '\t')) : (p -= 1) {}
        while (p > 0 and self.buffer.items[p - 1] != ' ' and self.buffer.items[p - 1] != '\t') : (p -= 1) {}
        self.cursor_pos = p;
    }

    pub fn transposeChars(self: *Editor) void {
        if (self.buffer.items.len < 2 or self.cursor_pos == 0) return;
        const idx = if (self.cursor_pos < self.buffer.items.len) self.cursor_pos else self.buffer.items.len - 1;
        const tmp = self.buffer.items[idx - 1];
        self.buffer.items[idx - 1] = self.buffer.items[idx];
        self.buffer.items[idx] = tmp;
        if (self.cursor_pos < self.buffer.items.len) self.cursor_pos += 1;
    }

    pub fn resetRenderState(self: *Editor) void {
        self.first_render = true;
        self.rendered_cursor_row = 0;
        self.rendered_total_rows = 0;
        self.rendered_menu_rows = 0;
    }

    pub fn clearScreen(self: *Editor) !void {
        terminal.writeAll(self.term.tty_fd, "\x1b[2J\x1b[H");
        self.resetRenderState();
    }

    pub fn cleanMenu(self: *Editor) void {
        if (self.rendered_menu_rows > 0) {
            var clear_buf = ArrayList(u8).init(self.allocator);
            defer clear_buf.deinit();
            const down = if (self.rendered_total_rows > self.rendered_cursor_row + 1)
                (self.rendered_total_rows - 1) - self.rendered_cursor_row
            else
                0;
            if (down > 0) render.appendFmt(&clear_buf, "\x1b[{d}B", .{down}) catch {};
            render.writeClearMenu(&clear_buf, self.rendered_menu_rows) catch {};
            if (down > 0) render.appendFmt(&clear_buf, "\x1b[{d}A", .{down}) catch {};
            terminal.writeAll(self.term.tty_fd, clear_buf.items);
            self.rendered_menu_rows = 0;
        }
    }

    pub fn editAndExecute(self: *Editor) !bool {
        const editor_cmd = self.environ.getPosix("VISUAL") orelse
            self.environ.getPosix("EDITOR") orelse
            "nano";

        var tmp_buf: [128]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_buf, "/tmp/ghost_edit_{d}.sh", .{posix.system.getpid()});

        var tmp_content = ArrayList(u8).init(self.allocator);
        defer tmp_content.deinit();
        try tmp_content.appendSlice(self.buffer.items);
        try tmp_content.append('\n');

        try writeFile(tmp_path, tmp_content.items);
        defer deleteFile(tmp_path);

        var term_ptr = @constCast(self.term);
        self.cleanMenu();
        term_ptr.suspendRaw();

        var child_opt = std.process.spawn(self.io, .{
            .argv = &[_][]const u8{ editor_cmd, tmp_path },
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch null;

        if (child_opt) |*child| {
            _ = child.wait(self.io) catch {};
        } else {
            var fallback = std.process.spawn(self.io, .{
                .argv = &[_][]const u8{ "vi", tmp_path },
                .stdin = .inherit,
                .stdout = .inherit,
                .stderr = .inherit,
            }) catch null;
            if (fallback) |*fb| _ = fb.wait(self.io) catch {};
        }

        try term_ptr.resumeRaw();

        const content = readFileAlloc(self.allocator, tmp_path, 1024 * 1024) orelse return false;
        defer self.allocator.free(content);

        const trimmed = std.mem.trimEnd(u8, content, " \t\r\n");
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(trimmed);
        self.cursor_pos = self.buffer.items.len;

        if (trimmed.len > 0) return true;
        self.resetRenderState();
        return false;
    }

    fn sanitizeCtrlRCommand(allocator: std.mem.Allocator, cmd: []const u8) ![]u8 {
        var res = ArrayList(u8).init(allocator);
        errdefer res.deinit();

        var i: usize = 0;
        while (i < cmd.len) {
            if (std.mem.startsWith(u8, cmd[i..], "--tty=/dev/tty")) {
                i += "--tty=/dev/tty".len;
            } else if (std.mem.startsWith(u8, cmd[i..], "--tty /dev/tty")) {
                i += "--tty /dev/tty".len;
            } else if (std.mem.startsWith(u8, cmd[i..], "--tty") and (i + 5 == cmd.len or cmd[i + 5] == ' ' or cmd[i + 5] == '\t')) {
                i += 5;
            } else {
                try res.append(cmd[i]);
                i += 1;
            }
        }
        return res.toOwnedSlice();
    }

    pub fn historySearchInteractive(self: *Editor) !bool {
        if (self.history.items.len == 0) return false;

        if (self.environ.getPosix("GHOST_CTRL_R_COMMAND")) |cmd| {
            if (cmd.len > 0) {
                var term_ptr = @constCast(self.term);
                self.cleanMenu();
                term_ptr.suspendRaw();

                var selected_opt: ?[]const u8 = null;

                const clean_cmd = sanitizeCtrlRCommand(self.allocator, cmd) catch cmd;
                defer if (clean_cmd.ptr != cmd.ptr) self.allocator.free(clean_cmd);

                var child_res = std.process.spawn(self.io, .{
                    .argv = &[_][]const u8{
                        "bash",
                        "--norc",
                        "-c",
                        clean_cmd,
                        "_",
                        self.buffer.items,
                    },
                    .stdin = .pipe,
                    .stdout = .pipe,
                    .stderr = .inherit,
                }) catch null;

                if (child_res) |*child| {
                    if (child.stdin) |stdin_file| {
                        for (self.history.items) |h| {
                            terminal.writeAll(stdin_file.handle, h);
                            terminal.writeAll(stdin_file.handle, "\n");
                        }
                        _ = posix.system.close(stdin_file.handle);
                        child.stdin = null;
                    }

                    var out_list = ArrayList(u8).init(self.allocator);
                    defer out_list.deinit();

                    if (child.stdout) |stdout_file| {
                        var buf: [1024]u8 = undefined;
                        while (true) {
                            const rc = posix.system.read(stdout_file.handle, &buf, buf.len);
                            if (posix.errno(rc) != .SUCCESS or rc == 0) break;
                            out_list.appendSlice(buf[0..@intCast(rc)]) catch break;
                        }
                        _ = posix.system.close(stdout_file.handle);
                        child.stdout = null;
                    }

                    const term_res = child.wait(self.io) catch null;
                    if (term_res) |res| {
                        if (res == .exited and res.exited == 0 and out_list.items.len > 0) {
                            selected_opt = self.allocator.dupe(u8, std.mem.trimEnd(u8, out_list.items, "\r\n")) catch null;
                        }
                    }
                }

                try term_ptr.resumeRaw();

                if (selected_opt) |sel| {
                    defer self.allocator.free(sel);
                    self.buffer.clearRetainingCapacity();
                    try self.buffer.appendSlice(sel);
                    self.cursor_pos = self.buffer.items.len;
                    self.hist_index = null;
                }

                self.resetRenderState();
                return true;
            }
        }

        self.startIsearch();
        return false;
    }

    pub fn startIsearch(self: *Editor) void {
        self.cleanMenu();
        self.in_completion = false;
        self.in_isearch = true;
        self.isearch_query.clearRetainingCapacity();
        self.saved_input.clearRetainingCapacity();
        self.saved_input.appendSlice(self.buffer.items) catch {};
        self.isearch_match_index = null;
        self.updateIsearchMatch(true);
    }

    pub fn cancelIsearch(self: *Editor) void {
        self.in_isearch = false;
        self.buffer.clearRetainingCapacity();
        self.buffer.appendSlice(self.saved_input.items) catch {};
        self.cursor_pos = self.buffer.items.len;
        self.isearch_query.clearRetainingCapacity();
        self.isearch_match_index = null;
    }

    pub fn acceptIsearch(self: *Editor) void {
        self.in_isearch = false;
        self.isearch_query.clearRetainingCapacity();
        self.isearch_match_index = null;
    }

    pub fn updateIsearchMatch(self: *Editor, forward_or_first: bool) void {
        _ = forward_or_first;
        if (self.history.items.len == 0) return;
        const q = self.isearch_query.items;
        if (q.len == 0) {
            self.isearch_match_index = null;
            self.buffer.clearRetainingCapacity();
            self.buffer.appendSlice(self.saved_input.items) catch {};
            self.cursor_pos = self.buffer.items.len;
            return;
        }

        const start_idx = if (self.isearch_match_index) |cur| cur else 0;
        var i = start_idx;
        while (i < self.history.items.len) : (i += 1) {
            if (std.mem.indexOf(u8, self.history.items[i], q)) |_| {
                self.isearch_match_index = i;
                self.buffer.clearRetainingCapacity();
                self.buffer.appendSlice(self.history.items[i]) catch {};
                self.cursor_pos = self.buffer.items.len;
                return;
            }
        }

        if (start_idx > 0) {
            i = 0;
            while (i < start_idx) : (i += 1) {
                if (std.mem.indexOf(u8, self.history.items[i], q)) |_| {
                    self.isearch_match_index = i;
                    self.buffer.clearRetainingCapacity();
                    self.buffer.appendSlice(self.history.items[i]) catch {};
                    self.cursor_pos = self.buffer.items.len;
                    return;
                }
            }
        }
    }

    pub fn isearchNextMatch(self: *Editor) void {
        if (self.history.items.len == 0) return;
        const q = self.isearch_query.items;
        if (q.len == 0) return;

        const start_idx = if (self.isearch_match_index) |cur| cur + 1 else 0;
        var i = start_idx;
        while (i < self.history.items.len) : (i += 1) {
            if (std.mem.indexOf(u8, self.history.items[i], q)) |_| {
                self.isearch_match_index = i;
                self.buffer.clearRetainingCapacity();
                self.buffer.appendSlice(self.history.items[i]) catch {};
                self.cursor_pos = self.buffer.items.len;
                return;
            }
        }

        i = 0;
        while (i < start_idx and i < self.history.items.len) : (i += 1) {
            if (std.mem.indexOf(u8, self.history.items[i], q)) |_| {
                self.isearch_match_index = i;
                self.buffer.clearRetainingCapacity();
                self.buffer.appendSlice(self.history.items[i]) catch {};
                self.cursor_pos = self.buffer.items.len;
                return;
            }
        }
    }

    pub fn isearchInsertChar(self: *Editor, cp: u21) !void {
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch return;
        try self.isearch_query.appendSlice(utf8_buf[0..len]);
        self.updateIsearchMatch(true);
    }

    pub fn isearchDeleteBackward(self: *Editor) void {
        if (self.isearch_query.items.len == 0) return;
        var step: usize = 1;
        const from = self.isearch_query.items.len;
        while (from >= step and (self.isearch_query.items[from - step] & 0xC0) == 0x80) step += 1;
        self.isearch_query.shrinkRetainingCapacity(from - step);
        self.isearch_match_index = null;
        self.updateIsearchMatch(true);
    }

    pub fn historyUp(self: *Editor) void {
        if (self.history.items.len == 0) return;
        if (self.hist_index == null) {
            self.saved_input.clearRetainingCapacity();
            self.saved_input.appendSlice(self.buffer.items) catch return;
            self.hist_index = 0;
        } else if (self.hist_index.? + 1 < self.history.items.len) {
            self.hist_index.? += 1;
        } else {
            return;
        }

        self.buffer.clearRetainingCapacity();
        self.buffer.appendSlice(self.history.items[self.hist_index.?]) catch return;
        self.cursor_pos = self.buffer.items.len;
    }

    pub fn historyDown(self: *Editor) void {
        if (self.hist_index == null) return;
        if (self.hist_index.? > 0) {
            self.hist_index.? -= 1;
            self.buffer.clearRetainingCapacity();
            self.buffer.appendSlice(self.history.items[self.hist_index.?]) catch return;
            self.cursor_pos = self.buffer.items.len;
        } else {
            self.hist_index = null;
            self.buffer.clearRetainingCapacity();
            self.buffer.appendSlice(self.saved_input.items) catch return;
            self.cursor_pos = self.buffer.items.len;
        }
    }

    pub fn applySelectedCompletion(self: *Editor, add_space_if_file: bool) void {
        if (self.candidates.items.len == 0) return;
        const cand = self.candidates.items[self.selected_candidate];
        self.deleteRange(self.comp_start_byte, self.cursor_pos - self.comp_start_byte);
        self.cursor_pos = self.comp_start_byte;
        self.insertSlice(cand) catch return;
        if (add_space_if_file and cand.len > 0 and cand[cand.len - 1] != '/' and cand[cand.len - 1] != ' ' and cand[cand.len - 1] != '=') {
            self.insertSlice(" ") catch return;
        }
    }
};

test "Editor updateGhost history match" {
    const allocator = std.testing.allocator;
    const term = try Term.init();
    defer @constCast(&term).deinit();

    var editor = Editor.init(allocator, std.testing.io, std.process.Environ.empty, &term, "> ");
    defer editor.deinit();

    const h1 = try allocator.dupe(u8, "git checkout -b feature-test");
    try editor.history.append(h1);

    try editor.buffer.appendSlice("git che");
    editor.cursor_pos = editor.buffer.items.len;
    editor.updateGhost();

    try std.testing.expect(editor.ghost_suggestion != null);
    try std.testing.expectEqualStrings("ckout -b feature-test", editor.ghost_suggestion.?);

    editor.acceptGhost();
    try std.testing.expectEqualStrings("git checkout -b feature-test", editor.buffer.items);
    try std.testing.expectEqual(editor.buffer.items.len, editor.cursor_pos);
    try std.testing.expect(editor.ghost_suggestion == null);
}

test "Editor updateGhost command fallback and pipes" {
    const allocator = std.testing.allocator;
    const term = try Term.init();
    defer @constCast(&term).deinit();

    var editor = Editor.init(allocator, std.testing.io, std.process.Environ.empty, &term, "> ");
    defer editor.deinit();

    try editor.buffer.appendSlice("gi");
    editor.cursor_pos = editor.buffer.items.len;
    editor.updateGhost();

    try std.testing.expect(editor.ghost_suggestion != null);
    try std.testing.expectEqualStrings("t", editor.ghost_suggestion.?);

    editor.buffer.clearRetainingCapacity();
    try editor.buffer.appendSlice("cat /etc/hosts | gr");
    editor.cursor_pos = editor.buffer.items.len;
    editor.updateGhost();

    try std.testing.expect(editor.ghost_suggestion != null);
    try std.testing.expectEqualStrings("ep", editor.ghost_suggestion.?);

    editor.acceptGhost();
    try std.testing.expectEqualStrings("cat /etc/hosts | grep", editor.buffer.items);

    editor.buffer.clearRetainingCapacity();
    try editor.buffer.appendSlice("cd /tmp && mk");
    editor.cursor_pos = editor.buffer.items.len;
    editor.updateGhost();

    try std.testing.expect(editor.ghost_suggestion != null);
    try std.testing.expectEqualStrings("dir", editor.ghost_suggestion.?);

    editor.buffer.clearRetainingCapacity();
    try editor.buffer.appendSlice("cat src/com");
    editor.cursor_pos = editor.buffer.items.len;
    editor.updateGhost();

    try std.testing.expect(editor.ghost_suggestion != null);
    try std.testing.expectEqualStrings("pletion.zig", editor.ghost_suggestion.?);
}

test "Editor expandHistoryLine and yankLastArg" {
    const allocator = std.testing.allocator;
    const term = try Term.init();
    defer @constCast(&term).deinit();

    var editor = Editor.init(allocator, std.testing.io, std.process.Environ.empty, &term, "> ");
    defer editor.deinit();

    const h1 = try allocator.dupe(u8, "git commit -m \"first commit\" file1.txt");
    const h2 = try allocator.dupe(u8, "echo hello file2.txt");
    try editor.history.append(h1);
    try editor.history.append(h2);

    try editor.buffer.appendSlice("sudo !!");
    editor.cursor_pos = editor.buffer.items.len;
    const expanded = editor.expandHistoryLine();
    try std.testing.expect(expanded);
    try std.testing.expectEqualStrings("sudo git commit -m \"first commit\" file1.txt", editor.buffer.items);

    editor.buffer.clearRetainingCapacity();
    try editor.buffer.appendSlice("cat !$");
    editor.cursor_pos = editor.buffer.items.len;
    try std.testing.expect(editor.expandHistoryLine());
    try std.testing.expectEqualStrings("cat file1.txt", editor.buffer.items);

    editor.buffer.clearRetainingCapacity();
    try editor.buffer.appendSlice("ls ");
    editor.cursor_pos = editor.buffer.items.len;

    editor.yankLastArg();
    try std.testing.expectEqualStrings("ls file1.txt", editor.buffer.items);

    editor.yankLastArg();
    try std.testing.expectEqualStrings("ls file2.txt", editor.buffer.items);
}

test "Editor sanitizeCtrlRCommand" {
    const allocator = std.testing.allocator;

    const c1 = try Editor.sanitizeCtrlRCommand(allocator, "fzf --height=40% --reverse --scheme=history --tiebreak=index --tty=/dev/tty");
    defer allocator.free(c1);
    try std.testing.expectEqualStrings("fzf --height=40% --reverse --scheme=history --tiebreak=index ", c1);

    const c2 = try Editor.sanitizeCtrlRCommand(allocator, "fzf --reverse --tty=/dev/tty");
    defer allocator.free(c2);
    try std.testing.expectEqualStrings("fzf --reverse ", c2);

    const c3 = try Editor.sanitizeCtrlRCommand(allocator, "fzf --tty /dev/tty --reverse");
    defer allocator.free(c3);
    try std.testing.expectEqualStrings("fzf  --reverse", c3);

    const c4 = try Editor.sanitizeCtrlRCommand(allocator, "fzf --reverse");
    defer allocator.free(c4);
    try std.testing.expectEqualStrings("fzf --reverse", c4);
}

test "Editor updateGhost completion fallback" {
    const allocator = std.testing.allocator;
    const term = try Term.init();
    defer @constCast(&term).deinit();

    var editor = Editor.init(allocator, std.testing.io, std.process.Environ.empty, &term, "> ");
    defer editor.deinit();

    try editor.buffer.appendSlice("git ad");
    editor.cursor_pos = editor.buffer.items.len;
    editor.updateGhost();

    try std.testing.expect(editor.ghost_suggestion != null);
    try std.testing.expect(std.mem.startsWith(u8, editor.ghost_suggestion.?, "d"));

    editor.acceptGhost();
    try std.testing.expect(std.mem.startsWith(u8, editor.buffer.items, "git add"));
}

test "Editor completion cache hit and env var ghost suggestion" {
    const allocator = std.testing.allocator;
    const term = try Term.init();
    defer @constCast(&term).deinit();

    var editor = Editor.init(allocator, std.testing.io, std.process.Environ.empty, &term, "> ");
    defer editor.deinit();

    // Test env var ghost suggestion
    try editor.buffer.appendSlice("echo $HO");
    editor.cursor_pos = editor.buffer.items.len;
    editor.updateGhost();
    try std.testing.expect(editor.ghost_suggestion != null);
    try std.testing.expectEqualStrings("ME", editor.ghost_suggestion.?);

    editor.buffer.clearRetainingCapacity();
    editor.completion_cache.clear();

    // First query populates cache
    try editor.buffer.appendSlice("git ad");
    editor.cursor_pos = editor.buffer.items.len;
    editor.updateGhost();

    try std.testing.expect(editor.completion_cache.prefix != null);
    try std.testing.expectEqualStrings("git ", editor.completion_cache.prefix.?);
    try std.testing.expect(editor.completion_cache.candidates.items.len > 0);

    // Typing another character uses the populated cache without querying again
    const old_cands_ptr = editor.completion_cache.candidates.items.ptr;
    try editor.buffer.appendSlice("d");
    editor.cursor_pos = editor.buffer.items.len;
    editor.updateGhost();

    // Cache pointer should remain identical (reused)
    try std.testing.expectEqual(old_cands_ptr, editor.completion_cache.candidates.items.ptr);

    // Changing prefix clears and updates cache
    editor.buffer.clearRetainingCapacity();
    try editor.buffer.appendSlice("cat src/com");
    editor.cursor_pos = editor.buffer.items.len;
    editor.updateGhost();
    try std.testing.expect(editor.ghost_suggestion != null);
    try std.testing.expectEqualStrings("pletion.zig", editor.ghost_suggestion.?);
}

