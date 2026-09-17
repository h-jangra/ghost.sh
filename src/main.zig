const std = @import("std");
const posix = std.posix;

const terminal = @import("terminal.zig");
const Term = terminal.Term;
const input = @import("input.zig");
const editor_mod = @import("editor.zig");
const Editor = editor_mod.Editor;
const render = @import("render.zig");
const MenuLayout = render.MenuLayout;
const completion = @import("completion.zig");
const history_expansion = @import("history_expansion.zig");

fn cancelLine(editor: *Editor) void {
    editor.cleanMenu();
    editor.buffer.clearRetainingCapacity();
    editor.cursor_pos = 0;
    editor.hist_index = null;
    editor.ghost_suggestion = null;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var prompt: []const u8 = "";
    var hist_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--prompt") or std.mem.eql(u8, arg, "-p")) {
            prompt = args.next() orelse "";
        } else if (std.mem.eql(u8, arg, "--histfile")) {
            hist_file = args.next();
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            output_file = args.next();
        }
    }

    var term = try Term.init();
    defer term.deinit();
    terminal.global_term_ptr = &term;
    defer terminal.global_term_ptr = null;

    const sa_int = posix.Sigaction{ .handler = .{ .handler = terminal.sigintHandler }, .mask = std.mem.zeroes(posix.system.sigset_t), .flags = 0 };
    posix.sigaction(posix.SIG.INT, &sa_int, null);
    const sa_term = posix.Sigaction{ .handler = .{ .handler = terminal.sigtermHandler }, .mask = std.mem.zeroes(posix.system.sigset_t), .flags = 0 };
    posix.sigaction(posix.SIG.TERM, &sa_term, null);

    try term.enableRaw();

    var editor = Editor.init(allocator, init.io, init.minimal.environ, &term, prompt);
    defer editor.deinit();

    if (hist_file) |hf| {
        editor.loadHistoryFromFile(hf);
    } else if (init.minimal.environ.getPosix("HISTFILE")) |hf| {
        editor.loadHistoryFromFile(hf);
    } else if (init.minimal.environ.getPosix("HOME")) |home| {
        var buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/.bash_history", .{home})) |p| editor.loadHistoryFromFile(p) else |_| {}
    }

    editor.updateGhost();
    try render.renderEditor(&editor);

    var exit_code: u8 = 0;
    var accepted = false;

    while (true) {
        const key = input.readKey(&term);

        if (editor.in_paste) {
            switch (key) {
                .paste_end => editor.in_paste = false,
                .char => |cp| try editor.insertChar(cp),
                .enter => try editor.insertSlice("\n"),
                .tab => try editor.insertSlice("\t"),
                else => {},
            }
            if (!editor.in_paste) {
                editor.updateGhost();
                try render.renderEditor(&editor);
            }
            continue;
        }

        if (editor.in_isearch) {
            switch (key) {
                .ctrl_r => editor.isearchNextMatch(),
                .backspace => editor.isearchDeleteBackward(),
                .char => |cp| try editor.isearchInsertChar(cp),
                .enter => {
                    editor.acceptIsearch();
                    accepted = true;
                    break;
                },
                .escape, .ctrl_c, .ctrl_g => editor.cancelIsearch(),
                else => editor.acceptIsearch(),
            }
            editor.updateGhost();
            try render.renderEditor(&editor);
            continue;
        }

        if (editor.in_completion) {
            const total = editor.candidates.items.len;
            const ws = term.getWindowSize();
            const cols: usize = if (ws.cols > 0) ws.cols else 80;
            const layout = MenuLayout.calculate(total, render.getMaxCandidateWidth(editor.candidates.items), cols);

            switch (key) {
                .tab, .right => {
                    editor.selected_candidate = (editor.selected_candidate + 1) % total;
                    editor.updateGhost();
                    try render.renderEditor(&editor);
                    continue;
                },
                .shift_tab, .left => {
                    editor.selected_candidate = (editor.selected_candidate + total - 1) % total;
                    editor.updateGhost();
                    try render.renderEditor(&editor);
                    continue;
                },
                .down => {
                    if (editor.selected_candidate + layout.num_cols < total) {
                        editor.selected_candidate += layout.num_cols;
                    } else {
                        editor.selected_candidate = (editor.selected_candidate + 1) % total;
                    }
                    editor.updateGhost();
                    try render.renderEditor(&editor);
                    continue;
                },
                .up => {
                    if (editor.selected_candidate >= layout.num_cols) {
                        editor.selected_candidate -= layout.num_cols;
                    } else {
                        editor.selected_candidate = (editor.selected_candidate + total - 1) % total;
                    }
                    editor.updateGhost();
                    try render.renderEditor(&editor);
                    continue;
                },
                .enter => {
                    editor.applySelectedCompletion(true);
                    editor.in_completion = false;
                    editor.updateGhost();
                    try render.renderEditor(&editor);
                    continue;
                },
                .escape, .ctrl_c => {
                    editor.in_completion = false;
                    editor.updateGhost();
                    try render.renderEditor(&editor);
                    continue;
                },
                else => {
                    editor.in_completion = false;
                },
            }
        }

        switch (key) {
            .paste_start => {
                editor.in_paste = true;
                continue;
            },
            .paste_end => editor.in_paste = false,
            .char => |cp| try editor.insertChar(cp),
            .backspace => editor.deleteBackward(),
            .delete => editor.deleteForward(),
            .left, .ctrl_b => editor.moveCursorLeft(),
            .right, .ctrl_f => editor.moveCursorRight(),
            .alt_f => editor.moveWordForward(),
            .alt_b => editor.moveWordBackward(),
            .alt_d => editor.killWordForward(),
            .alt_dot, .alt_underscore => editor.yankLastArg(),
            .alt_caret => _ = editor.expandHistoryLine(),
            .ctrl_t => editor.transposeChars(),
            .home, .ctrl_a => editor.cursor_pos = 0,
            .end, .ctrl_e => editor.moveCursorEnd(),
            .ctrl_w => editor.killWordBackward(),
            .ctrl_u => editor.killLineToStart(),
            .ctrl_k => editor.killLineToEnd(),
            .ctrl_l => try editor.clearScreen(),
            .ctrl_r => _ = try editor.historySearchInteractive(),
            .up => editor.historyUp(),
            .down => editor.historyDown(),
            .tab, .shift_tab => {
                if (!editor.expandHistoryLine()) {
                    editor.collectCompletions();
                    if (editor.candidates.items.len == 1) {
                        editor.selected_candidate = 0;
                        editor.applySelectedCompletion(true);
                    } else if (editor.candidates.items.len > 1) {
                        editor.in_completion = true;
                        editor.selected_candidate = 0;
                    }
                }
            },
            .enter => {
                const exp_res = history_expansion.expandHistory(allocator, editor.buffer.items, editor.history.items, "") catch null;
                if (exp_res) |res| {
                    defer allocator.free(res.expanded);
                    if (res.err_msg) |err| {
                        editor.cleanMenu();
                        terminal.writeAll(term.tty_fd, "\r\nghost: ");
                        terminal.writeAll(term.tty_fd, err);
                        terminal.writeAll(term.tty_fd, "\r\n");
                        editor.resetRenderState();
                        editor.updateGhost();
                        try render.renderEditor(&editor);
                        continue;
                    } else if (res.print_only) {
                        editor.buffer.clearRetainingCapacity();
                        try editor.buffer.appendSlice(res.expanded);
                        editor.cursor_pos = editor.buffer.items.len;
                        editor.cleanMenu();
                        terminal.writeAll(term.tty_fd, "\r\n");
                        editor.resetRenderState();
                        editor.updateGhost();
                        try render.renderEditor(&editor);
                        continue;
                    } else if (res.did_expand) {
                        editor.buffer.clearRetainingCapacity();
                        try editor.buffer.appendSlice(res.expanded);
                        editor.cursor_pos = editor.buffer.items.len;
                    }
                }
                accepted = true;
                break;
            },
            .ctrl_c => cancelLine(&editor),
            .ctrl_d => {
                if (editor.buffer.items.len == 0) {
                    exit_code = 1;
                    break;
                } else {
                    editor.deleteForward();
                }
            },
            .ctrl_x_e => {
                if (try editor.editAndExecute()) {
                    accepted = true;
                    break;
                }
            },
            .escape => {},
            else => {},
        }

        if (key != .alt_dot and key != .alt_underscore) editor.last_was_yank = false;

        editor.updateGhost();
        try render.renderEditor(&editor);
    }

    if (accepted) {
        editor.cursor_pos = editor.buffer.items.len;
        editor.ghost_suggestion = null;
        editor.in_completion = false;
        editor.in_isearch = false;
        try render.renderEditor(&editor);
    }
    editor.cleanMenu();
    terminal.writeAll(term.tty_fd, "\r\n");
    term.disableRaw();

    if (accepted) {
        if (output_file) |out_path| {
            var path_z: [4096:0]u8 = undefined;
            if (completion.toCStr(&path_z, out_path)) |pz| {
                const fd = posix.system.open(pz.ptr, posix.system.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
                if (posix.errno(fd) == .SUCCESS) {
                    defer _ = posix.system.close(@intCast(fd));
                    terminal.writeAll(@intCast(fd), editor.buffer.items);
                    terminal.writeAll(@intCast(fd), "\n");
                }
            }
        } else {
            terminal.writeAll(posix.STDOUT_FILENO, editor.buffer.items);
            terminal.writeAll(posix.STDOUT_FILENO, "\n");
        }
        return;
    }

    if (exit_code != 0) std.process.exit(exit_code);
}
