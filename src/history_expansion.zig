const std = @import("std");

pub fn ArrayList(comptime T: type) type {
    return std.array_list.AlignedManaged(T, null);
}

pub const ExpansionResult = struct {
    expanded: []const u8,
    did_expand: bool = false,
    print_only: bool = false,
    err_msg: ?[]const u8 = null,
};

pub fn splitWords(allocator: std.mem.Allocator, input: []const u8) !ArrayList([]const u8) {
    var words = ArrayList([]const u8).init(allocator);
    errdefer words.deinit();

    var i: usize = 0;
    while (i < input.len) {
        while (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\r' or input[i] == '\n')) : (i += 1) {}
        if (i >= input.len) break;

        const start = i;
        var in_single = false;
        var in_double = false;

        while (i < input.len) {
            const c = input[i];
            if (c == '\\' and !in_single and i + 1 < input.len) {
                i += 2;
                continue;
            }
            if (c == '\'' and !in_double) {
                in_single = !in_single;
                i += 1;
                continue;
            }
            if (c == '"' and !in_single) {
                in_double = !in_double;
                i += 1;
                continue;
            }
            if (!in_single and !in_double and (c == ' ' or c == '\t' or c == '\r' or c == '\n')) break;
            i += 1;
        }

        const word = input[start..i];
        if (word.len > 0) try words.append(word);
    }
    return words;
}

pub fn getLastArg(allocator: std.mem.Allocator, cmd: []const u8) !?[]const u8 {
    var words = try splitWords(allocator, cmd);
    defer words.deinit();
    if (words.items.len == 0) return null;
    return try allocator.dupe(u8, words.items[words.items.len - 1]);
}

fn applyModifier(allocator: std.mem.Allocator, str: []const u8, mod: []const u8) !struct { res: []const u8, print_only: bool, err_msg: ?[]const u8 } {
    if (mod.len == 0) return .{ .res = try allocator.dupe(u8, str), .print_only = false, .err_msg = null };

    switch (mod[0]) {
        'h' => {
            if (std.mem.lastIndexOfScalar(u8, str, '/')) |idx| {
                const head = if (idx == 0) "/" else str[0..idx];
                return .{ .res = try allocator.dupe(u8, head), .print_only = false, .err_msg = null };
            }
            return .{ .res = try allocator.dupe(u8, str), .print_only = false, .err_msg = null };
        },
        't' => {
            if (std.mem.lastIndexOfScalar(u8, str, '/')) |idx| {
                return .{ .res = try allocator.dupe(u8, str[idx + 1 ..]), .print_only = false, .err_msg = null };
            }
            return .{ .res = try allocator.dupe(u8, str), .print_only = false, .err_msg = null };
        },
        'r' => {
            const base_start = if (std.mem.lastIndexOfScalar(u8, str, '/')) |idx| idx + 1 else 0;
            const basename = str[base_start..];
            if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot_rel| {
                if (dot_rel > 0) return .{ .res = try allocator.dupe(u8, str[0 .. base_start + dot_rel]), .print_only = false, .err_msg = null };
            }
            return .{ .res = try allocator.dupe(u8, str), .print_only = false, .err_msg = null };
        },
        'e' => {
            const base_start = if (std.mem.lastIndexOfScalar(u8, str, '/')) |idx| idx + 1 else 0;
            const basename = str[base_start..];
            if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot_rel| {
                if (dot_rel > 0) return .{ .res = try allocator.dupe(u8, str[base_start + dot_rel ..]), .print_only = false, .err_msg = null };
            }
            return .{ .res = try allocator.dupe(u8, ""), .print_only = false, .err_msg = null };
        },
        'p' => return .{ .res = try allocator.dupe(u8, str), .print_only = true, .err_msg = null },
        'q' => {
            var list = ArrayList(u8).init(allocator);
            defer list.deinit();
            try list.append('\'');
            for (str) |c| {
                if (c == '\'') try list.appendSlice("'\\''") else try list.append(c);
            }
            try list.append('\'');
            return .{ .res = try list.toOwnedSlice(), .print_only = false, .err_msg = null };
        },
        'x' => {
            var words = try splitWords(allocator, str);
            defer words.deinit();
            var list = ArrayList(u8).init(allocator);
            defer list.deinit();
            for (words.items, 0..) |w, idx| {
                if (idx > 0) try list.append(' ');
                try list.append('\'');
                for (w) |c| {
                    if (c == '\'') try list.appendSlice("'\\''") else try list.append(c);
                }
                try list.append('\'');
            }
            return .{ .res = try list.toOwnedSlice(), .print_only = false, .err_msg = null };
        },
        's', 'g' => {
            const is_global = (mod[0] == 'g' and mod.len >= 2 and mod[1] == 's');
            if (mod[0] == 's' or is_global) {
                const s_idx: usize = if (is_global) 2 else 1;
                if (mod.len <= s_idx) return .{ .res = try allocator.dupe(u8, str), .print_only = false, .err_msg = "substitution failed" };
                const delim = mod[s_idx];
                const rest = mod[s_idx + 1 ..];

                var old_str: []const u8 = "";
                var new_str: []const u8 = "";

                if (std.mem.indexOfScalar(u8, rest, delim)) |d1| {
                    old_str = rest[0..d1];
                    const after_d1 = rest[d1 + 1 ..];
                    if (std.mem.indexOfScalar(u8, after_d1, delim)) |d2| {
                        new_str = after_d1[0..d2];
                    } else {
                        new_str = after_d1;
                    }
                } else {
                    old_str = rest;
                }

                if (std.mem.indexOf(u8, str, old_str) == null) {
                    return .{ .res = try allocator.dupe(u8, str), .print_only = false, .err_msg = "substitution failed" };
                }

                var list = ArrayList(u8).init(allocator);
                defer list.deinit();

                if (is_global) {
                    var curr = str;
                    while (std.mem.indexOf(u8, curr, old_str)) |idx| {
                        try list.appendSlice(curr[0..idx]);
                        try list.appendSlice(new_str);
                        curr = curr[idx + old_str.len ..];
                        if (old_str.len == 0) break;
                    }
                    try list.appendSlice(curr);
                } else {
                    if (std.mem.indexOf(u8, str, old_str)) |idx| {
                        try list.appendSlice(str[0..idx]);
                        try list.appendSlice(new_str);
                        try list.appendSlice(str[idx + old_str.len ..]);
                    }
                }
                return .{ .res = try list.toOwnedSlice(), .print_only = false, .err_msg = null };
            }
        },
        else => {},
    }
    return .{ .res = try allocator.dupe(u8, str), .print_only = false, .err_msg = null };
}

fn applyModifiers(allocator: std.mem.Allocator, str: []const u8, modifiers: []const []const u8) !struct { res: []const u8, print_only: bool, err_msg: ?[]const u8 } {
    var cur = try allocator.dupe(u8, str);
    var print_only = false;

    for (modifiers) |mod| {
        const step = try applyModifier(allocator, cur, mod);
        allocator.free(cur);
        cur = @constCast(step.res);
        if (step.print_only) print_only = true;
        if (step.err_msg) |err| return .{ .res = cur, .print_only = print_only, .err_msg = err };
    }
    return .{ .res = cur, .print_only = print_only, .err_msg = null };
}

pub fn expandHistory(
    allocator: std.mem.Allocator,
    input: []const u8,
    history: []const []const u8,
    current_line_prefix: []const u8,
) !ExpansionResult {
    _ = current_line_prefix;
    if (input.len == 0) return ExpansionResult{ .expanded = try allocator.dupe(u8, input), .did_expand = false };

    if (input[0] == '^') {
        if (history.len == 0) return ExpansionResult{ .expanded = try allocator.dupe(u8, input), .err_msg = "!!: event not found" };

        const second_caret = std.mem.indexOfScalar(u8, input[1..], '^') orelse
            return ExpansionResult{ .expanded = try allocator.dupe(u8, input), .did_expand = false };

        const old_str = input[1 .. 1 + second_caret];
        const after_second = input[1 + second_caret + 1 ..];
        var new_str = after_second;
        var print_only = false;

        if (std.mem.indexOfScalar(u8, after_second, '^')) |third_caret| {
            new_str = after_second[0..third_caret];
            if (std.mem.eql(u8, after_second[third_caret + 1 ..], ":p")) print_only = true;
        }

        const prev = history[0];
        if (std.mem.indexOf(u8, prev, old_str)) |idx| {
            var out = ArrayList(u8).init(allocator);
            defer out.deinit();
            try out.appendSlice(prev[0..idx]);
            try out.appendSlice(new_str);
            try out.appendSlice(prev[idx + old_str.len ..]);
            return ExpansionResult{ .expanded = try out.toOwnedSlice(), .did_expand = true, .print_only = print_only };
        }
        return ExpansionResult{ .expanded = try allocator.dupe(u8, input), .err_msg = "^substitution failed" };
    }

    var out = ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var in_single = false;
    var did_expand = false;
    var print_only = false;
    var i: usize = 0;

    while (i < input.len) {
        const c = input[i];

        if (c == '\'' and (i == 0 or input[i - 1] != '\\')) {
            in_single = !in_single;
            try out.append(c);
            i += 1;
            continue;
        }

        if (in_single) {
            try out.append(c);
            i += 1;
            continue;
        }

        if (c == '\\' and i + 1 < input.len and input[i + 1] == '!') {
            try out.append('!');
            i += 2;
            continue;
        }

        if (c == '!') {
            if (i + 1 >= input.len or input[i + 1] == ' ' or input[i + 1] == '\t' or input[i + 1] == '\r' or input[i + 1] == '\n' or input[i + 1] == '=' or input[i + 1] == '(' or input[i + 1] == '"') {
                try out.append(c);
                i += 1;
                continue;
            }

            var event_str: ?[]const u8 = null;
            var direct_word_spec: ?[]const u8 = null;
            var pos = i + 1;

            if (pos < input.len and input[pos] == '!') {
                pos += 1;
                if (history.len == 0) return ExpansionResult{ .expanded = try out.toOwnedSlice(), .err_msg = "!!: event not found" };
                event_str = history[0];
            } else if (pos < input.len and input[pos] == '$') {
                pos += 1;
                if (history.len == 0) return ExpansionResult{ .expanded = try out.toOwnedSlice(), .err_msg = "!$: event not found" };
                event_str = history[0];
                direct_word_spec = "$";
            } else if (pos < input.len and input[pos] == '^') {
                pos += 1;
                if (history.len == 0) return ExpansionResult{ .expanded = try out.toOwnedSlice(), .err_msg = "!^: event not found" };
                event_str = history[0];
                direct_word_spec = "^";
            } else if (pos < input.len and input[pos] == '*') {
                pos += 1;
                if (history.len == 0) return ExpansionResult{ .expanded = try out.toOwnedSlice(), .err_msg = "!*: event not found" };
                event_str = history[0];
                direct_word_spec = "*";
            } else if (pos < input.len and input[pos] == '#') {
                pos += 1;
                event_str = out.items;
            } else if (pos < input.len and input[pos] == '-') {
                pos += 1;
                const num_start = pos;
                while (pos < input.len and input[pos] >= '0' and input[pos] <= '9') : (pos += 1) {}
                if (pos == num_start) {
                    try out.append('!');
                    try out.append('-');
                    i = pos;
                    continue;
                }
                const n = std.fmt.parseInt(usize, input[num_start..pos], 10) catch return ExpansionResult{ .expanded = try out.toOwnedSlice(), .err_msg = "event not found" };
                if (n == 0 or n > history.len) return ExpansionResult{ .expanded = try out.toOwnedSlice(), .err_msg = "event not found" };
                event_str = history[n - 1];
            } else if (pos < input.len and input[pos] >= '0' and input[pos] <= '9') {
                const num_start = pos;
                while (pos < input.len and input[pos] >= '0' and input[pos] <= '9') : (pos += 1) {}
                const n = std.fmt.parseInt(usize, input[num_start..pos], 10) catch return ExpansionResult{ .expanded = try out.toOwnedSlice(), .err_msg = "event not found" };
                if (n == 0 or n > history.len) return ExpansionResult{ .expanded = try out.toOwnedSlice(), .err_msg = "event not found" };
                event_str = history[history.len - n];
            } else if (pos < input.len and input[pos] == '?') {
                pos += 1;
                const search_start = pos;
                while (pos < input.len and input[pos] != '?' and input[pos] != ':' and input[pos] != ' ' and input[pos] != '\t' and input[pos] != '\r' and input[pos] != '\n') : (pos += 1) {}
                const query = input[search_start..pos];
                if (pos < input.len and input[pos] == '?') pos += 1;

                for (history) |h| {
                    if (std.mem.indexOf(u8, h, query) != null) {
                        event_str = h;
                        break;
                    }
                }
                if (event_str == null) return ExpansionResult{ .expanded = try out.toOwnedSlice(), .err_msg = "event not found" };
            } else if (pos < input.len and input[pos] == ':') {
                if (history.len == 0) return ExpansionResult{ .expanded = try out.toOwnedSlice(), .err_msg = "!!: event not found" };
                event_str = history[0];
            } else {
                const search_start = pos;
                while (pos < input.len and input[pos] != ':' and input[pos] != ' ' and input[pos] != '\t' and input[pos] != '\r' and input[pos] != '\n' and input[pos] != '$' and input[pos] != '^' and input[pos] != '*') : (pos += 1) {}
                const query = input[search_start..pos];
                if (query.len == 0) {
                    try out.append('!');
                    i = pos;
                    continue;
                }

                for (history) |h| {
                    if (std.mem.startsWith(u8, h, query)) {
                        event_str = h;
                        break;
                    }
                }
                if (event_str == null) return ExpansionResult{ .expanded = try out.toOwnedSlice(), .err_msg = "event not found" };
            }

            if (event_str == null) {
                try out.append('!');
                i += 1;
                continue;
            }

            var word_spec = direct_word_spec;
            var modifiers = ArrayList([]const u8).init(allocator);
            defer modifiers.deinit();

            while (pos < input.len and input[pos] == ':') {
                pos += 1;
                const mod_start = pos;

                if (pos < input.len and (input[pos] == 's' or (pos + 1 < input.len and input[pos] == 'g' and input[pos + 1] == 's'))) {
                    const is_g = (input[pos] == 'g');
                    pos += if (is_g) 2 else 1;
                    if (pos < input.len) {
                        const delim = input[pos];
                        pos += 1;
                        var delim_count: usize = 0;
                        while (pos < input.len and delim_count < 2 and input[pos] != ' ' and input[pos] != '\t' and input[pos] != '\r' and input[pos] != '\n') {
                            if (input[pos] == delim) delim_count += 1;
                            pos += 1;
                        }
                    }
                    try modifiers.append(input[mod_start..pos]);
                } else if (pos < input.len and (input[pos] == 'h' or input[pos] == 't' or input[pos] == 'r' or input[pos] == 'e' or input[pos] == 'p' or input[pos] == 'q' or input[pos] == 'x')) {
                    pos += 1;
                    try modifiers.append(input[mod_start..pos]);
                } else {
                    while (pos < input.len and input[pos] != ':' and input[pos] != ' ' and input[pos] != '\t' and input[pos] != '\r' and input[pos] != '\n') : (pos += 1) {}
                    if (pos > mod_start) word_spec = input[mod_start..pos];
                }
            }

            var event_words = try splitWords(allocator, event_str.?);
            defer event_words.deinit();

            var selected_text: []const u8 = "";
            var need_free_selected = false;

            if (word_spec) |ws| {
                if (std.mem.eql(u8, ws, "0")) {
                    selected_text = if (event_words.items.len > 0) event_words.items[0] else "";
                } else if (std.mem.eql(u8, ws, "^") or std.mem.eql(u8, ws, "1")) {
                    if (event_words.items.len >= 2) {
                        selected_text = event_words.items[1];
                    } else if (event_words.items.len == 1) {
                        selected_text = event_words.items[0];
                    } else {
                        return ExpansionResult{ .expanded = try out.toOwnedSlice(), .err_msg = "bad word specifier" };
                    }
                } else if (std.mem.eql(u8, ws, "$")) {
                    selected_text = if (event_words.items.len > 0) event_words.items[event_words.items.len - 1] else "";
                } else if (std.mem.eql(u8, ws, "*")) {
                    if (event_words.items.len > 1) {
                        var wlist = ArrayList(u8).init(allocator);
                        defer wlist.deinit();
                        for (event_words.items[1..], 0..) |w, idx| {
                            if (idx > 0) try wlist.append(' ');
                            try wlist.appendSlice(w);
                        }
                        selected_text = try wlist.toOwnedSlice();
                        need_free_selected = true;
                    } else {
                        selected_text = "";
                    }
                } else if (std.mem.indexOfScalar(u8, ws, '-')) |dash_idx| {
                    const first_part = ws[0..dash_idx];
                    const second_part = ws[dash_idx + 1 ..];
                    const start_w = if (first_part.len > 0) std.fmt.parseInt(usize, first_part, 10) catch 0 else 0;
                    var end_w = if (event_words.items.len > 0) event_words.items.len - 1 else 0;
                    if (second_part.len > 0) {
                        if (!std.mem.eql(u8, second_part, "$")) end_w = std.fmt.parseInt(usize, second_part, 10) catch end_w;
                    } else {
                        end_w = if (event_words.items.len > 1) event_words.items.len - 2 else 0;
                    }

                    if (start_w < event_words.items.len and start_w <= end_w) {
                        const actual_end = @min(end_w + 1, event_words.items.len);
                        var wlist = ArrayList(u8).init(allocator);
                        defer wlist.deinit();
                        for (event_words.items[start_w..actual_end], 0..) |w, idx| {
                            if (idx > 0) try wlist.append(' ');
                            try wlist.appendSlice(w);
                        }
                        selected_text = try wlist.toOwnedSlice();
                        need_free_selected = true;
                    } else {
                        selected_text = "";
                    }
                } else if (ws.len >= 2 and ws[ws.len - 1] == '*') {
                    const start_w = std.fmt.parseInt(usize, ws[0 .. ws.len - 1], 10) catch 0;
                    if (start_w < event_words.items.len) {
                        var wlist = ArrayList(u8).init(allocator);
                        defer wlist.deinit();
                        for (event_words.items[start_w..], 0..) |w, idx| {
                            if (idx > 0) try wlist.append(' ');
                            try wlist.appendSlice(w);
                        }
                        selected_text = try wlist.toOwnedSlice();
                        need_free_selected = true;
                    } else {
                        selected_text = "";
                    }
                } else {
                    const w_idx = std.fmt.parseInt(usize, ws, 10) catch 0;
                    if (w_idx < event_words.items.len) {
                        selected_text = event_words.items[w_idx];
                    } else {
                        return ExpansionResult{ .expanded = try out.toOwnedSlice(), .err_msg = "bad word specifier" };
                    }
                }
            } else {
                selected_text = event_str.?;
            }

            const mod_res = try applyModifiers(allocator, selected_text, modifiers.items);
            if (need_free_selected) allocator.free(selected_text);
            defer allocator.free(mod_res.res);

            if (mod_res.print_only) print_only = true;
            if (mod_res.err_msg) |err| return ExpansionResult{ .expanded = try out.toOwnedSlice(), .err_msg = err };

            try out.appendSlice(mod_res.res);
            did_expand = true;
            i = pos;
            continue;
        }

        try out.append(c);
        i += 1;
    }

    return ExpansionResult{
        .expanded = try out.toOwnedSlice(),
        .did_expand = did_expand,
        .print_only = print_only,
        .err_msg = null,
    };
}

test "splitWords standard and quotes" {
    const allocator = std.testing.allocator;
    var words = try splitWords(allocator, "git commit -m \"initial commit\" 'file name.txt'");
    defer words.deinit();

    try std.testing.expectEqual(@as(usize, 5), words.items.len);
    try std.testing.expectEqualStrings("git", words.items[0]);
    try std.testing.expectEqualStrings("commit", words.items[1]);
    try std.testing.expectEqualStrings("-m", words.items[2]);
    try std.testing.expectEqualStrings("\"initial commit\"", words.items[3]);
    try std.testing.expectEqualStrings("'file name.txt'", words.items[4]);
}

test "expandHistory basic designators" {
    const allocator = std.testing.allocator;
    const history = [_][]const u8{
        "echo /a/b/c.txt foo bar",
        "git status",
        "cargo build --release",
    };

    {
        const r = try expandHistory(allocator, "sudo !!", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(r.did_expand);
        try std.testing.expectEqualStrings("sudo echo /a/b/c.txt foo bar", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "cat !$", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(r.did_expand);
        try std.testing.expectEqualStrings("cat bar", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "ls !^", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(r.did_expand);
        try std.testing.expectEqualStrings("ls /a/b/c.txt", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "printf '%s\\n' !*", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(r.did_expand);
        try std.testing.expectEqualStrings("printf '%s\\n' /a/b/c.txt foo bar", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "!-2", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(r.did_expand);
        try std.testing.expectEqualStrings("git status", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "!car", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(r.did_expand);
        try std.testing.expectEqualStrings("cargo build --release", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "!?status?", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(r.did_expand);
        try std.testing.expectEqualStrings("git status", r.expanded);
    }
}

test "expandHistory word specifiers and modifiers" {
    const allocator = std.testing.allocator;
    const history = [_][]const u8{
        "echo /path/to/archive.tar.gz item1 item2 item3",
    };

    {
        const r = try expandHistory(allocator, "which !!:0", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expectEqualStrings("which echo", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "cd !!:1:h", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expectEqualStrings("cd /path/to", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "ls !!:1:t", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expectEqualStrings("ls archive.tar.gz", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "echo !!:1:t:r", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expectEqualStrings("echo archive.tar", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "echo !!:1:e", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expectEqualStrings("echo .gz", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "echo !!:2-3", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expectEqualStrings("echo item1 item2", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "echo !!:2*", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expectEqualStrings("echo item1 item2 item3", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "!!:s/echo/printf/", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expectEqualStrings("printf /path/to/archive.tar.gz item1 item2 item3", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "echo !!:q", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expectEqualStrings("echo 'echo /path/to/archive.tar.gz item1 item2 item3'", r.expanded);
    }
}

test "expandHistory quick substitution ^old^new" {
    const allocator = std.testing.allocator;
    const history = [_][]const u8{"git comit -m test"};
    const r = try expandHistory(allocator, "^comit^commit^", &history, "");
    defer allocator.free(r.expanded);
    try std.testing.expect(r.did_expand);
    try std.testing.expectEqualStrings("git commit -m test", r.expanded);
}

test "expandHistory quotes and escapes" {
    const allocator = std.testing.allocator;
    const history = [_][]const u8{"ls -la"};

    {
        const r = try expandHistory(allocator, "echo '!!'", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(!r.did_expand);
        try std.testing.expectEqualStrings("echo '!!'", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "echo \\!\\!", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(!r.did_expand);
        try std.testing.expectEqualStrings("echo !!", r.expanded);
    }
}

test "expandHistory multiple expansions and global modifiers" {
    const allocator = std.testing.allocator;
    const history = [_][]const u8{
        "echo file.txt",
        "foo bar foo baz",
    };

    {
        const r = try expandHistory(allocator, "cp !$ !$:r.bak", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(r.did_expand);
        try std.testing.expectEqualStrings("cp file.txt file.bak", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "!-2:gs/foo/qux/", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(r.did_expand);
        try std.testing.expectEqualStrings("qux bar qux baz", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "echo !!:x", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(r.did_expand);
        try std.testing.expectEqualStrings("echo 'echo' 'file.txt'", r.expanded);
    }
    {
        const r = try expandHistory(allocator, "echo first !#:1", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(r.did_expand);
        try std.testing.expectEqualStrings("echo first first", r.expanded);
    }
    {
        const r1 = try expandHistory(allocator, "!1", &history, "");
        defer allocator.free(r1.expanded);
        try std.testing.expectEqualStrings("foo bar foo baz", r1.expanded);

        const r2 = try expandHistory(allocator, "!2", &history, "");
        defer allocator.free(r2.expanded);
        try std.testing.expectEqualStrings("echo file.txt", r2.expanded);
    }
    {
        const r = try expandHistory(allocator, "!nonexistent", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(r.err_msg != null);
    }
    {
        const r = try expandHistory(allocator, "!!:99", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(r.err_msg != null);
    }
    {
        const r = try expandHistory(allocator, "!!:p", &history, "");
        defer allocator.free(r.expanded);
        try std.testing.expect(r.print_only);
        try std.testing.expectEqualStrings("echo file.txt", r.expanded);
    }
}
