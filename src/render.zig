const std = @import("std");
const terminal = @import("terminal.zig");
const Editor = @import("editor.zig").Editor;
const ArrayList = @import("editor.zig").ArrayList;

pub const MenuLayout = struct {
    col_w: usize,
    num_cols: usize,
    vis_rows: usize,
    total_rows: usize,

    pub fn calculate(candidates_len: usize, max_candidate_len: usize, term_cols: usize) MenuLayout {
        const col_w = @min(@max(max_candidate_len + 2, 12), term_cols);
        const num_cols = @max(if (term_cols >= col_w) term_cols / col_w else 1, 1);
        const total_rows = (candidates_len + num_cols - 1) / num_cols;
        return .{
            .col_w = col_w,
            .num_cols = num_cols,
            .vis_rows = @min(total_rows, 5),
            .total_rows = total_rows,
        };
    }
};

fn isFullWidth(cp: u21) bool {
    if (cp < 0x1100) return false;
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1F64F) or
        (cp >= 0x1F900 and cp <= 0x1F9FF) or
        (cp >= 0x20000 and cp <= 0x3FFFD);
}

pub fn skipNonPrinting(s: []const u8, i: usize) usize {
    if (i >= s.len) return i;
    const b = s[i];
    if (b == 0x01) {
        var j = i + 1;
        while (j < s.len and s[j] != 0x02 and s[j] != '\n') : (j += 1) {}
        if (j < s.len and s[j] == 0x02) j += 1;
        return j;
    }
    if (b == 0x02) {
        return i + 1;
    }
    if (b == 0x1b) {
        if (i + 1 >= s.len) return i + 1;
        const next = s[i + 1];
        if (next == '[') {
            var j = i + 2;
            while (j < s.len and s[j] >= 0x20 and s[j] <= 0x3F) : (j += 1) {}
            if (j < s.len and s[j] >= 0x40 and s[j] <= 0x7E) j += 1;
            return j;
        }
        if (next == ']' or next == 'P' or next == '_' or next == '^' or next == 'X') {
            var j = i + 2;
            while (j < s.len) {
                if (s[j] == 0x07) {
                    j += 1;
                    break;
                }
                if (s[j] == 0x1b and j + 1 < s.len and s[j + 1] == '\\') {
                    j += 2;
                    break;
                }
                if (s[j] == 0x9c) {
                    j += 1;
                    break;
                }
                if (s[j] == '\n') break;
                j += 1;
            }
            return j;
        }
        if (next >= 0x20 and next <= 0x2F) {
            var j = i + 2;
            while (j < s.len and s[j] >= 0x20 and s[j] <= 0x2F) : (j += 1) {}
            if (j < s.len and s[j] >= 0x30 and s[j] <= 0x7E) j += 1;
            return j;
        }
        if (next >= 0x30 and next <= 0x7E) {
            return i + 2;
        }
        return i + 1;
    }
    return i;
}

pub fn getVisibleWidth(s: []const u8) usize {
    var last_line = s;
    if (std.mem.lastIndexOfScalar(u8, s, '\n')) |idx| last_line = s[idx + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, last_line, '\r')) |idx| last_line = last_line[idx + 1 ..];

    var w: usize = 0;
    var i: usize = 0;
    while (i < last_line.len) {
        const next_i = skipNonPrinting(last_line, i);
        if (next_i > i) {
            i = next_i;
            continue;
        }

        const b = last_line[i];
        if (b < 0x80) {
            if (b >= 32 and b != 127) w += 1;
            i += 1;
        } else {
            const seq_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
            if (i + seq_len <= last_line.len) {
                if (std.unicode.utf8Decode(last_line[i .. i + seq_len])) |cp| {
                    w += if (isFullWidth(cp)) 2 else 1;
                } else |_| {
                    w += 1;
                }
            } else {
                w += 1;
            }
            i += seq_len;
        }
    }
    return w;
}

pub fn appendFmt(list: *ArrayList(u8), comptime format: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&buf, format, args)) |formatted| {
        try list.appendSlice(formatted);
    } else |_| {
        const alloc_formatted = try std.fmt.allocPrint(list.allocator, format, args);
        defer list.allocator.free(alloc_formatted);
        try list.appendSlice(alloc_formatted);
    }
}

pub fn writeClearMenu(list: *ArrayList(u8), rows: usize) !void {
    if (rows == 0) return;
    var r: usize = 0;
    while (r < rows) : (r += 1) try list.appendSlice("\n\r\x1b[2K");
    try appendFmt(list, "\x1b[{d}A", .{rows});
}

pub fn getMaxCandidateWidth(candidates: []const []const u8) usize {
    var max_len: usize = 0;
    for (candidates) |c| {
        const cw = getVisibleWidth(c);
        if (cw > max_len) max_len = cw;
    }
    return max_len;
}

pub fn appendBufferWithCrlf(buf: *ArrayList(u8), text: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\r') {
            if (i + 1 < text.len and text[i + 1] == '\n') {
                try buf.appendSlice(text[start .. i + 2]);
                i += 2;
                start = i;
            } else {
                try buf.appendSlice(text[start .. i + 1]);
                i += 1;
                start = i;
            }
        } else if (text[i] == '\n') {
            try buf.appendSlice(text[start..i]);
            try buf.appendSlice("\r\n");
            i += 1;
            start = i;
        } else {
            i += 1;
        }
    }
    if (start < text.len) {
        try buf.appendSlice(text[start..]);
    }
}

pub const TextLayout = struct {
    cursor_row: usize,
    cursor_col: usize,
    end_row: usize,
    end_col: usize,
    total_rows: usize,
};

fn advanceCol(row: *usize, col: *usize, w: usize, cols: usize) void {
    if (w == 0) return;
    if (col.* + w > cols) {
        row.* += 1;
        col.* = if (w <= cols) w else cols;
    } else {
        col.* += w;
    }
}

fn advanceTab(row: *usize, col: *usize, cols: usize) void {
    const tab_w: usize = 8 - (col.* % 8);
    if (col.* + tab_w > cols) {
        row.* += 1;
        col.* = (col.* + tab_w) - cols;
        if (col.* >= cols) col.* = cols - 1;
    } else {
        col.* += tab_w;
    }
}

fn processSlice(
    slice: []const u8,
    cursor_pos_opt: ?usize,
    row: *usize,
    col: *usize,
    cursor_row: *usize,
    cursor_col: *usize,
    cursor_recorded: *bool,
    cols: usize,
) void {
    var i: usize = 0;
    while (i < slice.len) {
        if (cursor_pos_opt) |cp| {
            if (!cursor_recorded.* and i >= cp) {
                cursor_row.* = row.*;
                cursor_col.* = col.*;
                cursor_recorded.* = true;
            }
        }

        const next_i = skipNonPrinting(slice, i);
        if (next_i > i) {
            i = next_i;
            continue;
        }

        const b = slice[i];
        if (b == '\n') {
            row.* += 1;
            col.* = 0;
            i += 1;
        } else if (b == '\r') {
            col.* = 0;
            i += 1;
            if (i < slice.len and slice[i] == '\n') {
                row.* += 1;
                i += 1;
            }
        } else if (b == '\t') {
            advanceTab(row, col, cols);
            i += 1;
        } else {
            var w: usize = 1;
            var seq_len: usize = 1;
            if (b < 0x80) {
                w = if (b >= 32 and b != 127) 1 else 0;
                seq_len = 1;
            } else {
                seq_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
                if (i + seq_len <= slice.len) {
                    if (std.unicode.utf8Decode(slice[i .. i + seq_len])) |cp| {
                        w = if (isFullWidth(cp)) 2 else 1;
                    } else |_| {
                        w = 1;
                    }
                } else {
                    seq_len = 1;
                    w = 1;
                }
            }
            advanceCol(row, col, w, cols);
            i += seq_len;
        }
    }
}

pub fn calculateLayout(
    prompt_w: usize,
    buffer: []const u8,
    cursor_pos: usize,
    ghost_suggestion: ?[]const u8,
    term_cols: usize,
) TextLayout {
    const cols = if (term_cols > 0) term_cols else 80;
    var row: usize = prompt_w / cols;
    var col: usize = prompt_w % cols;

    var cursor_row: usize = row;
    var cursor_col: usize = col;
    var cursor_recorded: bool = false;

    if (cursor_pos == 0) {
        cursor_row = row;
        cursor_col = col;
        cursor_recorded = true;
    }

    processSlice(
        buffer,
        cursor_pos,
        &row,
        &col,
        &cursor_row,
        &cursor_col,
        &cursor_recorded,
        cols,
    );

    if (!cursor_recorded) {
        cursor_row = row;
        cursor_col = col;
        cursor_recorded = true;
    }

    if (ghost_suggestion) |ghost| {
        processSlice(
            ghost,
            null,
            &row,
            &col,
            &cursor_row,
            &cursor_col,
            &cursor_recorded,
            cols,
        );
    }

    const end_row = row;
    const end_col = col;
    const total_rows = end_row + 1;

    return .{
        .cursor_row = cursor_row,
        .cursor_col = if (cols > 0) @min(cursor_col, cols - 1) else cursor_col,
        .end_row = end_row,
        .end_col = if (cols > 0) @min(end_col, cols - 1) else end_col,
        .total_rows = total_rows,
    };
}

pub fn renderEditor(editor: *Editor) !void {
    editor.render_buf.clearRetainingCapacity();
    const buf = &editor.render_buf;

    const ws = editor.term.getWindowSize();
    const term_cols: usize = if (ws.cols > 0) ws.cols else 80;

    // Hide cursor while rendering
    try buf.appendSlice("\x1b[?25l");

    // If first render, output prefix of multi-line prompt if any
    if (editor.first_render and editor.prompt_prefix.len > 0) {
        try appendBufferWithCrlf(buf, editor.prompt_prefix);
    }

    // Step 1: Move from previous cursor position back to prompt origin (Row 0, Col 0)
    if (!editor.first_render and editor.rendered_cursor_row > 0) {
        try appendFmt(buf, "\x1b[{d}A", .{editor.rendered_cursor_row});
    }
    try buf.appendSlice("\r");

    // Step 2: Clear all previously rendered rows
    const old_rows = if (editor.first_render) 0 else (editor.rendered_total_rows + editor.rendered_menu_rows);
    if (old_rows > 1) {
        try buf.appendSlice("\x1b[2K");
        var r: usize = 1;
        while (r < old_rows) : (r += 1) {
            try buf.appendSlice("\x1b[B\x1b[2K");
        }
        try appendFmt(buf, "\x1b[{d}A\r", .{old_rows - 1});
    } else {
        try buf.appendSlice("\x1b[2K");
    }

    editor.first_render = false;

    if (editor.in_isearch) {
        var prefix_buf: [256]u8 = undefined;
        const prefix_str = std.fmt.bufPrint(&prefix_buf, "(reverse-i-search)`{s}': ", .{editor.isearch_query.items}) catch "(reverse-i-search)`': ";
        const prefix_w = getVisibleWidth(prefix_str);

        var match_pos: usize = editor.buffer.items.len;
        if (editor.isearch_query.items.len > 0) {
            if (std.mem.indexOf(u8, editor.buffer.items, editor.isearch_query.items)) |idx| {
                match_pos = idx;
            }
        }

        const isearch_layout = calculateLayout(prefix_w, editor.buffer.items, match_pos, null, term_cols);

        try buf.appendSlice(prefix_str);
        try appendBufferWithCrlf(buf, editor.buffer.items);

        const rows_up = isearch_layout.end_row - isearch_layout.cursor_row;
        if (rows_up > 0) {
            try appendFmt(buf, "\x1b[{d}A", .{rows_up});
        }
        try buf.appendSlice("\r");
        if (isearch_layout.cursor_col > 0) {
            try appendFmt(buf, "\x1b[{d}C", .{isearch_layout.cursor_col});
        }

        editor.rendered_cursor_row = isearch_layout.cursor_row;
        editor.rendered_total_rows = isearch_layout.total_rows;
        editor.rendered_menu_rows = 0;

        try buf.appendSlice("\x1b[?25h");
        terminal.writeAll(editor.term.tty_fd, buf.items);
        return;
    }

    const layout = calculateLayout(
        editor.prompt_vis_w,
        editor.buffer.items,
        editor.cursor_pos,
        editor.ghost_suggestion,
        term_cols,
    );

    try buf.appendSlice(editor.prompt_last_line);
    try appendBufferWithCrlf(buf, editor.buffer.items);

    if (editor.ghost_suggestion) |sugg| {
        try buf.appendSlice("\x1b[38;5;244m");
        try appendBufferWithCrlf(buf, sugg);
        try buf.appendSlice("\x1b[0m");
    }

    var vis_rows: usize = 0;
    if (editor.in_completion and editor.candidates.items.len > 0) {
        const max_w = if (editor.max_candidate_width > 0) editor.max_candidate_width else getMaxCandidateWidth(editor.candidates.items);
        const menu_layout = MenuLayout.calculate(editor.candidates.items.len, max_w, term_cols);
        vis_rows = menu_layout.vis_rows;

        const cur_row = editor.selected_candidate / menu_layout.num_cols;
        const start_row = if (cur_row >= vis_rows) cur_row - vis_rows + 1 else 0;

        var r = start_row;
        var drawn_lines: usize = 0;
        while (r < start_row + vis_rows and r < menu_layout.total_rows) : (r += 1) {
            try buf.appendSlice("\n\r\x1b[2K");
            drawn_lines += 1;
            var c: usize = 0;
            while (c < menu_layout.num_cols) : (c += 1) {
                const idx = r * menu_layout.num_cols + c;
                if (idx < editor.candidates.items.len) {
                    const item = editor.candidates.items[idx];
                    const is_selected = (idx == editor.selected_candidate);
                    const is_dir = (item.len > 0 and item[item.len - 1] == '/');

                    if (is_selected) {
                        try buf.appendSlice("\x1b[7m");
                    } else if (is_dir) {
                        try buf.appendSlice("\x1b[1;34m");
                    }

                    const item_vw = getVisibleWidth(item);
                    if (item_vw > menu_layout.col_w - 1 and menu_layout.col_w >= 3) {
                        var trunc_bytes: usize = 0;
                        var cur_w: usize = 0;
                        while (trunc_bytes < item.len and cur_w + 2 < menu_layout.col_w) {
                            const next_tb = skipNonPrinting(item, trunc_bytes);
                            if (next_tb > trunc_bytes) {
                                trunc_bytes = next_tb;
                                continue;
                            }
                            const slen = std.unicode.utf8ByteSequenceLength(item[trunc_bytes]) catch 1;
                            if (trunc_bytes + slen > item.len) break;
                            cur_w += if (isFullWidth(std.unicode.utf8Decode(item[trunc_bytes .. trunc_bytes + slen]) catch 0)) 2 else 1;
                            trunc_bytes += slen;
                        }
                        try buf.appendSlice(item[0..trunc_bytes]);
                        try buf.appendSlice("…");
                        if (menu_layout.col_w > cur_w + 2) {
                            var pad = (menu_layout.col_w - 1) - (cur_w + 1);
                            while (pad > 0) : (pad -= 1) try buf.append(' ');
                        }
                    } else {
                        try buf.appendSlice(item);
                        if (menu_layout.col_w > item_vw + 1) {
                            var pad = (menu_layout.col_w - 1) - item_vw;
                            while (pad > 0) : (pad -= 1) try buf.append(' ');
                        }
                    }
                    try buf.appendSlice("\x1b[0m ");
                }
            }
        }

        if (drawn_lines > 0) try appendFmt(buf, "\x1b[{d}A", .{drawn_lines});
    }
    editor.rendered_menu_rows = vis_rows;

    const rows_up = layout.end_row - layout.cursor_row;
    if (rows_up > 0) {
        try appendFmt(buf, "\x1b[{d}A", .{rows_up});
    }
    try buf.appendSlice("\r");
    if (layout.cursor_col > 0) {
        try appendFmt(buf, "\x1b[{d}C", .{layout.cursor_col});
    }

    editor.rendered_cursor_row = layout.cursor_row;
    editor.rendered_total_rows = layout.total_rows;

    try buf.appendSlice("\x1b[?25h");
    terminal.writeAll(editor.term.tty_fd, buf.items);
}

test "renderEditor with and without ghost suggestion" {
    const allocator = std.testing.allocator;
    const term = try terminal.Term.init();
    defer @constCast(&term).deinit();

    var ed = Editor.init(allocator, std.testing.io, std.process.Environ.empty, &term, "> ");
    defer ed.deinit();

    try ed.buffer.appendSlice("ll");
    ed.cursor_pos = ed.buffer.items.len;
    ed.ghost_suggestion = "c";

    try renderEditor(&ed);
    try std.testing.expect(std.mem.indexOf(u8, ed.render_buf.items, "\x1b[38;5;244mc\x1b[0m") != null);

    ed.ghost_suggestion = null;
    try renderEditor(&ed);
    try std.testing.expect(std.mem.indexOf(u8, ed.render_buf.items, "\x1b[38;5;244m") == null);
    try std.testing.expect(std.mem.indexOf(u8, ed.render_buf.items, "> ll") != null);
}

test "calculateLayout single line and multi line" {
    // Single line
    const l1 = calculateLayout(2, "hello", 5, null, 80);
    try std.testing.expectEqual(@as(usize, 0), l1.cursor_row);
    try std.testing.expectEqual(@as(usize, 7), l1.cursor_col);
    try std.testing.expectEqual(@as(usize, 0), l1.end_row);
    try std.testing.expectEqual(@as(usize, 7), l1.end_col);
    try std.testing.expectEqual(@as(usize, 1), l1.total_rows);

    // Multi line with \n
    const multiline = "line1\nline2\nline3";
    const l2 = calculateLayout(2, multiline, multiline.len, null, 80);
    try std.testing.expectEqual(@as(usize, 2), l2.cursor_row);
    try std.testing.expectEqual(@as(usize, 5), l2.cursor_col);
    try std.testing.expectEqual(@as(usize, 2), l2.end_row);
    try std.testing.expectEqual(@as(usize, 5), l2.end_col);
    try std.testing.expectEqual(@as(usize, 3), l2.total_rows);

    // Cursor in the middle of multiline
    const l3 = calculateLayout(2, multiline, 2, null, 80);
    try std.testing.expectEqual(@as(usize, 0), l3.cursor_row);
    try std.testing.expectEqual(@as(usize, 4), l3.cursor_col); // prompt 2 + "li" (2)
    try std.testing.expectEqual(@as(usize, 2), l3.end_row);
    try std.testing.expectEqual(@as(usize, 3), l3.total_rows);
}

test "calculateLayout wrapping on terminal width" {
    // 10 cols, prompt width 2, command 15 'a's
    const text = "aaaaaaaaaaaaaaa";
    // Cursor at index 3: row 0, col 5 (2 + 3)
    const l1 = calculateLayout(2, text, 3, null, 10);
    try std.testing.expectEqual(@as(usize, 0), l1.cursor_row);
    try std.testing.expectEqual(@as(usize, 5), l1.cursor_col);
    try std.testing.expectEqual(@as(usize, 1), l1.end_row);
    try std.testing.expectEqual(@as(usize, 2), l1.total_rows);

    // With ghost suggestion that wraps into row 2
    const ghost = "bbbbbbbbbb";
    const l2 = calculateLayout(2, text, 3, ghost, 10);
    try std.testing.expectEqual(@as(usize, 0), l2.cursor_row);
    try std.testing.expectEqual(@as(usize, 5), l2.cursor_col);
    try std.testing.expectEqual(@as(usize, 2), l2.end_row);
    try std.testing.expectEqual(@as(usize, 3), l2.total_rows);
}

test "renderEditor multi-line clean redraw without duplication" {
    const allocator = std.testing.allocator;
    const term = try terminal.Term.init();
    defer @constCast(&term).deinit();

    var ed = Editor.init(allocator, std.testing.io, std.process.Environ.empty, &term, "> ");
    defer ed.deinit();

    try ed.buffer.appendSlice("first line\nsecond line");
    ed.cursor_pos = ed.buffer.items.len;

    // Render 1
    try renderEditor(&ed);
    try std.testing.expectEqual(@as(usize, 1), ed.rendered_cursor_row);
    try std.testing.expectEqual(@as(usize, 2), ed.rendered_total_rows);

    // Render 2 (simulating next event / keystroke)
    try renderEditor(&ed);
    // Verifying it moved up 1 line (\x1b[1A) and cleared 2 rows (\x1b[2K...\x1b[B\x1b[2K)
    try std.testing.expect(std.mem.indexOf(u8, ed.render_buf.items, "\x1b[1A\r\x1b[2K\x1b[B\x1b[2K\x1b[1A\r") != null);
    try std.testing.expectEqual(@as(usize, 1), ed.rendered_cursor_row);
    try std.testing.expectEqual(@as(usize, 2), ed.rendered_total_rows);
}

test "skipNonPrinting and getVisibleWidth with Kitty shell integration" {
    // Exact Kitty PS1 expanded string from bash with kitty shell integration
    const kitty_ps1 = "\x01\x1b]133;k;start_kitty\x07\x02\x01\x1b]133;D;0\x07\x1b]133;A\x07\x02\x01\x1b]133;k;end_kitty\x07\x02bash-5.3$ \x01\x1b]133;k;start_suffix_kitty\x07\x02\x01\x1b[5 q\x02\x01\x1b]2;~/Projects/ghost.sh\x07\x02\x01\x1b]133;k;end_suffix_kitty\x07\x02";

    // Visible width must be exactly 10 for "bash-5.3$ ", NOT 86
    const vw = getVisibleWidth(kitty_ps1);
    try std.testing.expectEqual(@as(usize, 10), vw);
}

test "skipNonPrinting with ST string terminator and CSI with modifiers" {
    // OSC terminated with ST (\x1b\)
    const osc_st = "\x1b]2;My Terminal Title\x1b\\user$ ";
    try std.testing.expectEqual(@as(usize, 6), getVisibleWidth(osc_st));

    // Kitty cursor shape escape \x1b[5 q
    const cursor_shape = "\x1b[5 qhello";
    try std.testing.expectEqual(@as(usize, 5), getVisibleWidth(cursor_shape));

    // SGR colors
    const colored = "\x1b[38;2;255;0;0mRED\x1b[0m";
    try std.testing.expectEqual(@as(usize, 3), getVisibleWidth(colored));
}

test "renderEditor cursor column with Kitty prompt" {
    const allocator = std.testing.allocator;
    const term = try terminal.Term.init();
    defer @constCast(&term).deinit();

    const kitty_ps1 = "\x01\x1b]133;k;start_kitty\x07\x02\x01\x1b]133;D;0\x07\x1b]133;A\x07\x02\x01\x1b]133;k;end_kitty\x07\x02bash-5.3$ \x01\x1b]133;k;start_suffix_kitty\x07\x02\x01\x1b[5 q\x02\x01\x1b]2;~/Projects/ghost.sh\x07\x02\x01\x1b]133;k;end_suffix_kitty\x07\x02";

    var ed = Editor.init(allocator, std.testing.io, std.process.Environ.empty, &term, kitty_ps1);
    defer ed.deinit();

    try renderEditor(&ed);

    // Prompt visible width must be 10
    try std.testing.expectEqual(@as(usize, 10), ed.prompt_vis_w);

    // Cursor position in render buffer must move forward 10 columns, not 80+ columns
    try std.testing.expect(std.mem.indexOf(u8, ed.render_buf.items, "\r\x1b[10C") != null);
    try std.testing.expectEqual(@as(usize, 0), ed.rendered_cursor_row);
    try std.testing.expectEqual(@as(usize, 1), ed.rendered_total_rows);
}

