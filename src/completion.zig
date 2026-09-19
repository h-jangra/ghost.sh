const std = @import("std");
const posix = std.posix;

const BASH_COMPLETION_SCRIPT =
    \\if [[ -n "${BASH_COMPLETION:-}" && -r "$BASH_COMPLETION" ]]; then
    \\    . "$BASH_COMPLETION" 2>/dev/null
    \\else
    \\    for f in "${BASH_COMPLETION_USER_DIR:-$HOME/.local/share/bash-completion}/bash_completion" \
    \\             /usr/share/bash-completion/bash_completion \
    \\             /etc/bash_completion; do
    \\        [[ -r "$f" ]] && . "$f" 2>/dev/null && break
    \\    done
    \\fi
    \\
    \\line="$1" point="${2:-${#line}}"
    \\pre="${line:0:point}"
    \\cmd_pre="$pre"
    \\for ((i=${#pre}-1; i>=0; i--)); do
    \\    ch="${pre:i:1}"
    \\    if [[ "$ch" == '|' || "$ch" == ';' || "$ch" == '&' || "$ch" == '(' || "$ch" == ')' || "$ch" == '`' ]]; then
    \\        cmd_pre="${pre:i+1}"
    \\        break
    \\    fi
    \\done
    \\cmd_pre="${cmd_pre#"${cmd_pre%%[![:space:]]*}"}"
    \\
    \\read -ra words <<< "$cmd_pre"
    \\[[ "$cmd_pre" =~ [[:space:]]$ ]] && words+=("")
    \\cword=$(( ${#words[@]} - 1 ))
    \\(( cword == 0 )) && exit 0
    \\cur="${words[cword]:-}"
    \\cmd="${words[0]:-}"
    \\[[ -z "$cmd" ]] && exit 0
    \\prev=""
    \\(( cword > 0 )) && prev="${words[cword-1]}"
    \\
    \\comp_spec=""
    \\if (( cword > 0 )) && [[ -n "$cmd" ]]; then
    \\    comp_spec=$(complete -p "$cmd" 2>/dev/null || complete -p "${cmd##*/}" 2>/dev/null)
    \\    if [[ -z "$comp_spec" ]]; then
    \\        if [[ "$(complete -p -D 2>/dev/null)" =~ -F[[:space:]]+([^[:space:]]+) ]]; then
    \\            "${BASH_REMATCH[1]}" "$cmd" 2>/dev/null || "${BASH_REMATCH[1]}" "${cmd##*/}" 2>/dev/null
    \\        elif declare -F _completion_loader >/dev/null; then
    \\            _completion_loader "$cmd" 2>/dev/null || _completion_loader "${cmd##*/}" 2>/dev/null
    \\        elif declare -F _comp_load >/dev/null; then
    \\            _comp_load "$cmd" 2>/dev/null || _comp_load "${cmd##*/}" 2>/dev/null
    \\        fi
    \\        comp_spec=$(complete -p "$cmd" 2>/dev/null || complete -p "${cmd##*/}" 2>/dev/null)
    \\    fi
    \\fi
    \\[[ -z "$comp_spec" ]] && exit 0
    \\
    \\raw=()
    \\if [[ "$comp_spec" =~ -F[[:space:]]+([^[:space:]]+) ]]; then
    \\    func="${BASH_REMATCH[1]}"
    \\    if declare -F "$func" >/dev/null; then
    \\        COMP_LINE="$cmd_pre" COMP_POINT=${#cmd_pre} COMP_WORDS=("${words[@]}") COMP_CWORD=$cword COMP_KEY=9 COMP_TYPE=9 COMPREPLY=()
    \\        "$func" "$cmd" "$cur" "$prev" 2>/dev/null
    \\        raw=("${COMPREPLY[@]}")
    \\    fi
    \\elif [[ "$comp_spec" =~ -C[[:space:]]+(\'([^\']*)\'|\"([^\"]*)\"|([^[:space:]]+)) ]]; then
    \\    ccmd="${BASH_REMATCH[2]:-${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}}"
    \\    COMP_LINE="$cmd_pre" COMP_POINT=${#cmd_pre} COMP_WORDS=("${words[@]}") COMP_CWORD=$cword COMP_KEY=9 COMP_TYPE=9
    \\    mapfile -t raw < <(eval "$ccmd" "\"$cmd\"" "\"$cur\"" "\"$prev\"" 2>/dev/null)
    \\elif [[ "$comp_spec" =~ -W[[:space:]]+(\'([^\']*)\'|\"([^\"]*)\"|([^[:space:]]+)) ]]; then
    \\    mapfile -t raw < <(compgen -W "${BASH_REMATCH[2]:-${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}}" -- "$cur")
    \\elif [[ "$comp_spec" =~ -A[[:space:]]+([^[:space:]]+) ]]; then
    \\    mapfile -t raw < <(compgen -A "${BASH_REMATCH[1]}" -- "$cur")
    \\fi
    \\
    \\declare -A seen=()
    \\for m in "${raw[@]}"; do
    \\    [[ -z "$m" ]] && continue
    \\    [[ "$m" != */ && -d "$m" ]] && m+="/"
    \\    if [[ -z "${seen["$m"]:-}" ]]; then
    \\        seen["$m"]=1
    \\        printf "%s\n" "$m"
    \\    fi
    \\done
;

pub const BUILTINS_AND_KEYWORDS = [_][]const u8{
    "alias", "bg", "bind", "break", "builtin", "caller", "case", "cd",
    "command", "compgen", "complete", "compopt", "continue", "coproc",
    "declare", "dirs", "disown", "do", "done", "echo", "elif", "else",
    "enable", "esac", "eval", "exec", "exit", "export", "false", "fc",
    "fg", "fi", "for", "function", "getopts", "hash", "help", "history",
    "if", "in", "jobs", "kill", "let", "local", "logout", "mapfile",
    "popd", "printf", "pushd", "pwd", "read", "readarray", "readonly",
    "return", "select", "set", "shift", "shopt", "source", "suspend",
    "test", "then", "time", "times", "trap", "true", "type", "typeset",
    "ulimit", "umask", "unalias", "unset", "until", "wait", "while",
};

pub const COMMON_COMMANDS = [_][]const u8{
    "awk",        "bash",       "cat",        "cargo",      "cd",
    "chmod",      "chown",      "clear",      "cp",         "curl",
    "df",         "diff",       "docker",     "du",         "echo",
    "export",     "find",       "git",        "grep",       "gzip",
    "head",       "history",    "htop",       "kill",       "less",
    "ls",         "make",       "mkdir",      "more",       "mv",
    "nano",       "node",       "npm",        "ps",         "python",
    "python3",    "rm",         "rsync",      "scp",        "sed",
    "sh",         "source",     "ssh",        "sudo",       "systemctl",
    "tail",       "tar",        "tee",        "touch",      "tree",
    "vi",         "vim",        "wc",         "which",      "zig",
};

pub const FILE_ORIENTED_COMMANDS = [_][]const u8{
    "cat", "chmod", "chown", "cp", "head", "less", "ls", "more", "mv",
    "nano", "nvim", "rm", "tail", "touch", "vi", "vim", "wc", "mkdir",
};

pub fn isFileOrientedCommand(cmd: []const u8) bool {
    for (FILE_ORIENTED_COMMANDS) |fc| {
        if (std.mem.eql(u8, cmd, fc)) return true;
    }
    return false;
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.startsWithIgnoreCase(haystack[i..], needle)) return true;
    }
    return false;
}

pub fn fuzzyMatchIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var h_idx: usize = 0;
    var n_idx: usize = 0;
    while (h_idx < haystack.len and n_idx < needle.len) {
        if (std.ascii.toLower(haystack[h_idx]) == std.ascii.toLower(needle[n_idx])) n_idx += 1;
        h_idx += 1;
    }
    return n_idx == needle.len;
}

pub fn toCStr(buf: *[4096:0]u8, s: []const u8) ?[:0]const u8 {
    if (s.len >= buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

pub fn getProcEnviron(key: []const u8, out_buf: []u8) ?[]const u8 {
    const fd = posix.system.open("/proc/self/environ", posix.system.O{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (posix.errno(fd) != .SUCCESS) return null;
    defer _ = posix.system.close(@intCast(fd));

    var buf: [65536]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < buf.len) {
        const rc = posix.system.read(@intCast(fd), buf[total_read..].ptr, buf.len - total_read);
        if (posix.errno(rc) != .SUCCESS or rc == 0) break;
        total_read += @intCast(rc);
    }
    if (total_read == 0) return null;

    var it = std.mem.splitScalar(u8, buf[0..total_read], 0);
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry, key) and entry.len > key.len and entry[key.len] == '=') {
            const val = entry[key.len + 1 ..];
            if (val.len <= out_buf.len) {
                @memcpy(out_buf[0..val.len], val);
                return out_buf[0..val.len];
            }
        }
    }
    return null;
}

pub fn getEnv(env_obj: std.process.Environ, key: []const u8) ?[]const u8 {
    return env_obj.getPosix(key);
}

pub const DirEntry = struct {
    name: []const u8,
    d_type: u8,
};

pub fn iterateDir(fd: posix.fd_t, buf: *[8192]u8, ctx: anytype, comptime cb: fn (@TypeOf(ctx), DirEntry) bool) void {
    while (true) {
        const rc = posix.system.getdents64(fd, buf, buf.len);
        if (posix.errno(rc) != .SUCCESS or rc == 0) break;
        const n: usize = @intCast(rc);
        var pos: usize = 0;
        while (pos < n) {
            if (pos + 19 > n) break;
            const reclen = std.mem.readInt(u16, buf[pos + 16 .. pos + 18][0..2], .little);
            if (reclen == 0 or pos + reclen > n) break;
            const d_type = buf[pos + 18];
            const name_start = pos + 19;
            var name_end = name_start;
            while (name_end < pos + reclen and buf[name_end] != 0) : (name_end += 1) {}
            const name = buf[name_start..name_end];
            pos += reclen;
            if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (!cb(ctx, .{ .name = name, .d_type = d_type })) return;
        }
    }
}

fn comparePrefix(target: []const u8, item: []const u8) std.math.Order {
    return std.mem.order(u8, target, item);
}

pub const CommandCache = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    commands: std.array_list.AlignedManaged([]const u8, null),
    loaded: bool = false,

    pub fn init(allocator: std.mem.Allocator) CommandCache {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .commands = std.array_list.AlignedManaged([]const u8, null).init(allocator),
            .loaded = false,
        };
    }

    pub fn deinit(self: *CommandCache) void {
        self.commands.deinit();
        self.arena.deinit();
    }

    pub fn contains(self: *const CommandCache, target: []const u8) bool {
        const idx = std.sort.lowerBound([]const u8, self.commands.items, target, comparePrefix);
        return idx < self.commands.items.len and std.mem.eql(u8, self.commands.items[idx], target);
    }

    pub fn load(self: *CommandCache, env_obj: std.process.Environ) void {
        if (self.loaded) return;
        self.loaded = true;

        const arena_alloc = self.arena.allocator();
        var set = std.StringHashMap(void).init(self.allocator);
        defer set.deinit();

        for (BUILTINS_AND_KEYWORDS) |kw| {
            if (!set.contains(kw)) {
                const dup = arena_alloc.dupe(u8, kw) catch continue;
                set.put(dup, {}) catch continue;
                self.commands.append(dup) catch continue;
            }
        }

        var path_buf: [4096]u8 = undefined;
        const path_env = getEnv(env_obj, "PATH") orelse getProcEnviron("PATH", &path_buf) orelse "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
        var it = std.mem.splitScalar(u8, path_env, ':');
        var buf: [8192]u8 = undefined;

        const Ctx = struct {
            cache: *CommandCache,
            set: *std.StringHashMap(void),
            a: std.mem.Allocator,

            fn onEntry(c: @This(), entry: DirEntry) bool {
                if (entry.name[0] != '.' and (entry.d_type == 8 or entry.d_type == 10 or entry.d_type == 0)) {
                    if (!c.set.contains(entry.name)) {
                        const dup = c.a.dupe(u8, entry.name) catch return false;
                        c.set.put(dup, {}) catch return false;
                        c.cache.commands.append(dup) catch return false;
                    }
                }
                return true;
            }
        };

        while (it.next()) |dir_path| {
            var dir_z: [4096:0]u8 = undefined;
            const path_z = toCStr(&dir_z, dir_path) orelse continue;
            const fd = posix.system.open(path_z.ptr, posix.system.O{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
            if (posix.errno(fd) != .SUCCESS) continue;
            defer _ = posix.system.close(@intCast(fd));

            iterateDir(@intCast(fd), &buf, Ctx{ .cache = self, .set = &set, .a = arena_alloc }, Ctx.onEntry);
        }

        std.mem.sort([]const u8, self.commands.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
    }

    pub fn findMatch(self: *const CommandCache, prefix: []const u8) ?[]const u8 {
        if (prefix.len == 0) return null;

        for (COMMON_COMMANDS) |cc| {
            if (std.mem.startsWith(u8, cc, prefix) and cc.len > prefix.len and self.contains(cc)) return cc;
        }

        const idx = std.sort.lowerBound([]const u8, self.commands.items, prefix, comparePrefix);
        var best_match: ?[]const u8 = null;
        var best_len: usize = std.math.maxInt(usize);

        var i = idx;
        while (i < self.commands.items.len) : (i += 1) {
            const cmd = self.commands.items[i];
            if (!std.mem.startsWith(u8, cmd, prefix)) break;
            if (cmd.len > prefix.len and cmd.len < best_len) {
                best_len = cmd.len;
                best_match = cmd;
            }
        }
        return best_match;
    }
};

pub const CommandPositionInfo = struct {
    is_command_position: bool,
    prefix: []const u8,
};

pub fn getCommandPositionInfo(line: []const u8) CommandPositionInfo {
    if (line.len == 0) return .{ .is_command_position = true, .prefix = "" };

    var in_single_quote = false;
    var in_double_quote = false;
    var escaped = false;
    var last_sep_end: usize = 0;

    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\' and !in_single_quote) {
            escaped = true;
            continue;
        }
        if (c == '\'' and !in_double_quote) {
            in_single_quote = !in_single_quote;
            continue;
        }
        if (c == '"' and !in_single_quote) {
            in_double_quote = !in_double_quote;
            continue;
        }
        if (!in_single_quote and !in_double_quote) {
            if (c == '|' or c == ';' or c == '&' or c == '(' or c == '`' or c == '{' or c == '\n') {
                last_sep_end = i + 1;
            } else if (c == '$' and i + 1 < line.len and line[i + 1] == '(') {
                last_sep_end = i + 2;
                i += 1;
            }
        }
    }

    const seg = line[last_sep_end..];
    const WordItem = struct { slice: []const u8, has_trailing_space: bool };
    var words_buf: [64]WordItem = undefined;
    var words_len: usize = 0;

    var seg_i: usize = 0;
    in_single_quote = false;
    in_double_quote = false;
    escaped = false;

    while (seg_i < seg.len and words_len < words_buf.len) {
        while (seg_i < seg.len and (seg[seg_i] == ' ' or seg[seg_i] == '\t')) : (seg_i += 1) {}
        if (seg_i >= seg.len) break;

        const w_start = seg_i;
        while (seg_i < seg.len) : (seg_i += 1) {
            const sc = seg[seg_i];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (sc == '\\' and !in_single_quote) {
                escaped = true;
                continue;
            }
            if (sc == '\'' and !in_double_quote) {
                in_single_quote = !in_single_quote;
                continue;
            }
            if (sc == '"' and !in_single_quote) {
                in_double_quote = !in_double_quote;
                continue;
            }
            if (!in_single_quote and !in_double_quote and (sc == ' ' or sc == '\t')) break;
        }
        const w_end = seg_i;
        const trailing_space = (seg_i < seg.len and (seg[seg_i] == ' ' or seg[seg_i] == '\t'));
        words_buf[words_len] = .{ .slice = seg[w_start..w_end], .has_trailing_space = trailing_space };
        words_len += 1;
    }

    if (words_len == 0) return .{ .is_command_position = true, .prefix = "" };

    const WRAPPERS = [_][]const u8{
        "sudo", "doas", "env", "nohup", "time", "watch", "xargs", "which",
        "exec", "builtin", "command", "stdbuf", "nice", "ionice", "chroot",
    };

    var word_idx: usize = 0;
    var prev_was_opt_with_arg = false;

    while (word_idx < words_len) {
        const item = words_buf[word_idx];
        const w = item.slice;
        const is_last = (word_idx == words_len - 1 and !item.has_trailing_space);

        if (prev_was_opt_with_arg) {
            prev_was_opt_with_arg = false;
            if (is_last) return .{ .is_command_position = false, .prefix = w };
            word_idx += 1;
            continue;
        }

        const is_env = (std.mem.indexOfScalar(u8, w, '=') != null and w[0] != '-');
        var is_wrapper = false;
        for (WRAPPERS) |wr| {
            if (std.mem.eql(u8, w, wr)) {
                is_wrapper = true;
                break;
            }
        }

        if (is_wrapper or is_env) {
            if (is_last) return .{ .is_command_position = true, .prefix = w };
            word_idx += 1;
            continue;
        }

        if (w.len > 0 and w[0] == '-' and word_idx > 0) {
            if (is_last) return .{ .is_command_position = false, .prefix = w };
            if (std.mem.eql(u8, w, "-u") or std.mem.eql(u8, w, "-g") or std.mem.eql(u8, w, "-o") or
                std.mem.eql(u8, w, "-C") or std.mem.eql(u8, w, "-n") or std.mem.eql(u8, w, "-E"))
            {
                prev_was_opt_with_arg = true;
            }
            word_idx += 1;
            continue;
        }

        return .{ .is_command_position = is_last, .prefix = w };
    }

    return .{ .is_command_position = false, .prefix = "" };
}

fn isDirEntry(dir_fd: posix.fd_t, name: []const u8, d_type: u8) bool {
    if (d_type == 4) return true;
    if (d_type == 8) return false;
    var name_z: [4096:0]u8 = undefined;
    const path_z = toCStr(&name_z, name) orelse return false;
    const test_fd = posix.system.openat(dir_fd, path_z.ptr, posix.system.O{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (posix.errno(test_fd) == .SUCCESS) {
        _ = posix.system.close(@intCast(test_fd));
        return true;
    }
    return false;
}

pub fn expandPathNative(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    candidates: *std.array_list.AlignedManaged([]const u8, null),
    raw_path: []const u8,
    dirs_only: bool,
) void {
    var unesc_buf: [4096]u8 = undefined;
    var unesc_len: usize = 0;
    var ui: usize = 0;
    while (ui < raw_path.len and unesc_len < unesc_buf.len) : (ui += 1) {
        if (raw_path[ui] == '\\' and ui + 1 < raw_path.len) ui += 1;
        unesc_buf[unesc_len] = raw_path[ui];
        unesc_len += 1;
    }
    const unescaped_path = unesc_buf[0..unesc_len];

    var home_buf: [512]u8 = undefined;
    const home = getEnv(environ, "HOME") orelse getProcEnviron("HOME", &home_buf) orelse "/";
    var path_to_expand = unescaped_path;
    var root_dir: []const u8 = ".";
    var disp_prefix: []const u8 = "";

    if (std.mem.startsWith(u8, path_to_expand, "~/")) {
        disp_prefix = "~/";
        path_to_expand = path_to_expand[2..];
        root_dir = home;
    } else if (std.mem.eql(u8, path_to_expand, "~")) {
        addCandidate(allocator, candidates, "~/");
        return;
    } else if (std.mem.startsWith(u8, path_to_expand, "/")) {
        disp_prefix = "/";
        path_to_expand = path_to_expand[1..];
        root_dir = "/";
    }

    var root_buf: [4096]u8 = undefined;
    @memcpy(root_buf[0..root_dir.len], root_dir);
    var root_len = root_dir.len;

    var disp_buf: [4096]u8 = undefined;
    @memcpy(disp_buf[0..disp_prefix.len], disp_prefix);
    var disp_len = disp_prefix.len;

    while (true) {
        if (std.mem.startsWith(u8, path_to_expand, "../")) {
            if (disp_len + 3 <= disp_buf.len) {
                @memcpy(disp_buf[disp_len .. disp_len + 3], "../");
                disp_len += 3;
            }
            path_to_expand = path_to_expand[3..];
            if (root_len + 3 <= root_buf.len) {
                @memcpy(root_buf[root_len .. root_len + 3], "/..");
                root_len += 3;
            }
        } else if (std.mem.eql(u8, path_to_expand, "..")) {
            if (disp_len + 3 <= disp_buf.len) {
                @memcpy(disp_buf[disp_len .. disp_len + 3], "../");
                disp_len += 3;
            }
            addCandidate(allocator, candidates, disp_buf[0..disp_len]);
            return;
        } else if (std.mem.startsWith(u8, path_to_expand, "./")) {
            if (disp_len + 2 <= disp_buf.len) {
                @memcpy(disp_buf[disp_len .. disp_len + 2], "./");
                disp_len += 2;
            }
            path_to_expand = path_to_expand[2..];
            if (root_len + 2 <= root_buf.len) {
                @memcpy(root_buf[root_len .. root_len + 2], "/.");
                root_len += 2;
            }
        } else if (std.mem.eql(u8, path_to_expand, ".")) {
            if (disp_len + 2 <= disp_buf.len) {
                @memcpy(disp_buf[disp_len .. disp_len + 2], "./");
                disp_len += 2;
            }
            addCandidate(allocator, candidates, disp_buf[0..disp_len]);
            return;
        } else {
            break;
        }
    }

    var segments_list = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer segments_list.deinit();

    if (path_to_expand.len == 0) {
        segments_list.append("") catch return;
    } else {
        var it = std.mem.splitScalar(u8, path_to_expand, '/');
        while (it.next()) |s| segments_list.append(s) catch return;
    }

    const PathCandidate = struct {
        disk_path: []const u8,
        disp_path: []const u8,
        score: u32,
        is_dir: bool,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var current_paths = std.array_list.AlignedManaged(PathCandidate, null).init(a);
    const init_disk = a.dupe(u8, root_buf[0..root_len]) catch return;
    const init_disp = a.dupe(u8, disp_buf[0..disp_len]) catch return;
    current_paths.append(.{ .disk_path = init_disk, .disp_path = init_disp, .score = 0, .is_dir = true }) catch return;

    var dent_buf: [8192]u8 = undefined;

    for (segments_list.items, 0..) |seg, seg_idx| {
        const is_last = (seg_idx == segments_list.items.len - 1);
        var next_paths = std.array_list.AlignedManaged(PathCandidate, null).init(a);

        for (current_paths.items) |item| {
            if (!item.is_dir) continue;

            var disk_z: [4096:0]u8 = undefined;
            const path_z = toCStr(&disk_z, item.disk_path) orelse continue;

            const fd = posix.system.open(path_z.ptr, posix.system.O{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
            if (posix.errno(fd) != .SUCCESS) continue;
            defer _ = posix.system.close(@intCast(fd));

            const ScanCtx = struct {
                fd_cast: posix.fd_t,
                item: PathCandidate,
                seg: []const u8,
                seg_idx: usize,
                unescaped_path: []const u8,
                dirs_only: bool,
                is_last: bool,
                a_alloc: std.mem.Allocator,
                next_paths_ptr: *std.array_list.AlignedManaged(PathCandidate, null),

                fn onEntry(c: @This(), entry: DirEntry) bool {
                    const name = entry.name;
                    if (name[0] != '.' or (c.seg.len > 0 and c.seg[0] == '.') or (c.seg.len == 0 and c.seg_idx == 0 and c.unescaped_path.len > 0 and c.unescaped_path[0] == '.')) {
                        var match_score: ?u32 = null;
                        if (c.seg.len == 0 or std.mem.eql(u8, name, c.seg)) {
                            match_score = 0;
                        } else if (std.ascii.startsWithIgnoreCase(name, c.seg)) {
                            match_score = 1;
                        } else if (containsIgnoreCase(name, c.seg)) {
                            match_score = 2;
                        } else if (fuzzyMatchIgnoreCase(name, c.seg)) {
                            match_score = 3;
                        }

                        if (match_score) |ms| {
                            const is_dir = isDirEntry(c.fd_cast, name, entry.d_type);
                            if (!c.dirs_only or !c.is_last or is_dir) {
                                const total_score = c.item.score * 10 + ms;
                                const next_disp = if (is_dir)
                                    std.fmt.allocPrint(c.a_alloc, "{s}{s}/", .{ c.item.disp_path, name }) catch return false
                                else
                                    std.fmt.allocPrint(c.a_alloc, "{s}{s}", .{ c.item.disp_path, name }) catch return false;
                                const next_disk = std.fmt.allocPrint(c.a_alloc, "{s}/{s}", .{ c.item.disk_path, name }) catch return false;

                                c.next_paths_ptr.append(.{
                                    .disk_path = next_disk,
                                    .disp_path = next_disp,
                                    .score = total_score,
                                    .is_dir = is_dir,
                                }) catch return false;
                                if (c.next_paths_ptr.items.len >= 100) return false;
                            }
                        }
                    }
                    return true;
                }
            };

            iterateDir(@intCast(fd), &dent_buf, ScanCtx{
                .fd_cast = @intCast(fd),
                .item = item,
                .seg = seg,
                .seg_idx = seg_idx,
                .unescaped_path = unescaped_path,
                .dirs_only = dirs_only,
                .is_last = is_last,
                .a_alloc = a,
                .next_paths_ptr = &next_paths,
            }, ScanCtx.onEntry);
        }

        current_paths = next_paths;
        if (current_paths.items.len == 0) break;
        if (current_paths.items.len > 50) {
            std.mem.sort(PathCandidate, current_paths.items, {}, struct {
                fn lessThan(_: void, p1: PathCandidate, p2: PathCandidate) bool {
                    return p1.score < p2.score;
                }
            }.lessThan);
            current_paths.items.len = 50;
        }
    }

    std.mem.sort(PathCandidate, current_paths.items, {}, struct {
        fn lessThan(_: void, p1: PathCandidate, p2: PathCandidate) bool {
            if (p1.score != p2.score) return p1.score < p2.score;
            return std.mem.order(u8, p1.disp_path, p2.disp_path) == .lt;
        }
    }.lessThan);

    for (current_paths.items) |c| addCandidate(allocator, candidates, c.disp_path);
}

pub fn findPathMatch(environ: std.process.Environ, raw_path: []const u8, result_buf: []u8) ?[]const u8 {
    if (raw_path.len == 0) return null;

    var dir_part: []const u8 = "";
    var file_prefix: []const u8 = raw_path;

    if (std.mem.lastIndexOfScalar(u8, raw_path, '/')) |idx| {
        dir_part = raw_path[0 .. idx + 1];
        file_prefix = raw_path[idx + 1 ..];
    }

    var resolved_dir_buf: [4096]u8 = undefined;
    var resolved_dir: []const u8 = ".";

    if (dir_part.len > 0) {
        if (std.mem.startsWith(u8, dir_part, "~/")) {
            var home_buf: [512]u8 = undefined;
            const home = getEnv(environ, "HOME") orelse getProcEnviron("HOME", &home_buf) orelse "/";
            resolved_dir = std.fmt.bufPrint(&resolved_dir_buf, "{s}/{s}", .{ home, dir_part[2..] }) catch return null;
        } else if (std.mem.eql(u8, dir_part, "~")) {
            var home_buf: [512]u8 = undefined;
            resolved_dir = getEnv(environ, "HOME") orelse getProcEnviron("HOME", &home_buf) orelse "/";
        } else {
            resolved_dir = dir_part;
        }
    }

    var path_to_open = resolved_dir;
    if (path_to_open.len > 1 and path_to_open[path_to_open.len - 1] == '/') path_to_open = path_to_open[0 .. path_to_open.len - 1];

    var path_to_open_buf: [4096:0]u8 = undefined;
    const path_z = toCStr(&path_to_open_buf, path_to_open) orelse return null;

    const fd = posix.system.open(path_z.ptr, posix.system.O{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (posix.errno(fd) != .SUCCESS) return null;
    defer _ = posix.system.close(@intCast(fd));

    const MatchCtx = struct {
        fd_cast: posix.fd_t,
        file_prefix: []const u8,
        best_match_buf: *[512]u8,
        best_match_len: usize = 0,
        best_match_is_dir: bool = false,
        exact_prefix_found: bool = false,

        fn onEntry(c: *@This(), entry: DirEntry) bool {
            const name = entry.name;
            if (name[0] != '.' or (c.file_prefix.len > 0 and c.file_prefix[0] == '.')) {
                var matches = false;
                var is_exact = false;
                if (std.mem.startsWith(u8, name, c.file_prefix) and name.len > c.file_prefix.len) {
                    matches = true;
                    is_exact = true;
                } else if (!c.exact_prefix_found and name.len > c.file_prefix.len and std.ascii.startsWithIgnoreCase(name, c.file_prefix)) {
                    matches = true;
                }

                if (matches) {
                    const is_dir = isDirEntry(c.fd_cast, name, entry.d_type);
                    if (is_exact and !c.exact_prefix_found) {
                        c.exact_prefix_found = true;
                        c.best_match_len = @min(name.len, c.best_match_buf.len);
                        @memcpy(c.best_match_buf[0..c.best_match_len], name[0..c.best_match_len]);
                        c.best_match_is_dir = is_dir;
                    } else if (c.best_match_len == 0 or name.len < c.best_match_len) {
                        c.best_match_len = @min(name.len, c.best_match_buf.len);
                        @memcpy(c.best_match_buf[0..c.best_match_len], name[0..c.best_match_len]);
                        c.best_match_is_dir = is_dir;
                    }
                }
            }
            return true;
        }
    };

    var best_buf: [512]u8 = undefined;
    var match_ctx = MatchCtx{
        .fd_cast = @intCast(fd),
        .file_prefix = file_prefix,
        .best_match_buf = &best_buf,
    };
    var dent_buf: [8192]u8 = undefined;
    iterateDir(@intCast(fd), &dent_buf, &match_ctx, MatchCtx.onEntry);

    if (match_ctx.best_match_len > file_prefix.len) {
        const full_match = best_buf[0..match_ctx.best_match_len];
        const suffix = full_match[file_prefix.len..];
        const out_len = suffix.len;
        if (match_ctx.best_match_is_dir and out_len + 1 <= result_buf.len) {
            @memcpy(result_buf[0..out_len], suffix);
            result_buf[out_len] = '/';
            return result_buf[0 .. out_len + 1];
        } else if (out_len <= result_buf.len) {
            @memcpy(result_buf[0..out_len], suffix);
            return result_buf[0..out_len];
        }
    }
    return null;
}

pub fn findArgumentPathMatch(environ: std.process.Environ, line: []const u8, result_buf: []u8) ?[]const u8 {
    if (line.len == 0) return null;
    const last_char = line[line.len - 1];
    if (last_char == ' ' or last_char == '\t' or last_char == '|' or last_char == '&' or last_char == ';') return null;
    const start = findCompletionStart(line, line.len);
    const token = line[start..];
    if (token.len == 0) return null;
    return findPathMatch(environ, token, result_buf);
}

pub fn findCompletionStart(line: []const u8, pt: usize) usize {
    var start: usize = pt;
    while (start > 0) {
        const ch = line[start - 1];
        if (ch == ' ' or ch == '\t') {
            var bs_count: usize = 0;
            var b: usize = start - 1;
            while (b > 0 and line[b - 1] == '\\') : (b -= 1) bs_count += 1;
            if (bs_count % 2 == 0) break;
        } else if (ch == '|' or ch == '&' or ch == ';' or ch == '(' or ch == ')' or ch == '<' or ch == '>') {
            break;
        }
        start -= 1;
    }
    return start;
}

pub fn addCandidate(allocator: std.mem.Allocator, candidates: *std.array_list.AlignedManaged([]const u8, null), cand: []const u8) void {
    for (candidates.items) |c| {
        if (std.mem.eql(u8, c, cand)) return;
    }
    if (candidates.items.len >= 200) return;
    const dup = allocator.dupe(u8, cand) catch return;
    candidates.append(dup) catch allocator.free(dup);
}

pub fn collectBashCompletions(
    allocator: std.mem.Allocator,
    io: std.Io,
    candidates: *std.array_list.AlignedManaged([]const u8, null),
    line: []const u8,
    pt: usize,
) void {
    var pt_buf: [32]u8 = undefined;
    const pt_str = std.fmt.bufPrint(&pt_buf, "{d}", .{pt}) catch return;

    const res = std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "bash", "--norc", "-c", BASH_COMPLETION_SCRIPT, "_", line, pt_str },
        .stdout_limit = std.Io.Limit.limited(128 * 1024),
    }) catch return;
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) return;

    var it = std.mem.splitScalar(u8, res.stdout, '\n');
    while (it.next()) |raw_line| {
        const cand = std.mem.trimEnd(u8, raw_line, "\r");
        if (cand.len > 0) addCandidate(allocator, candidates, cand);
    }
}

fn collectZoxideCompletions(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    candidates: *std.array_list.AlignedManaged([]const u8, null),
    token: []const u8,
) void {
    if (token.len == 0) return;

    const argv: []const []const u8 = &[_][]const u8{ "zoxide", "query", "-l", "--", token };

    const res = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(128 * 1024),
    }) catch return;
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) return;

    var pwd_buf: [4096]u8 = undefined;
    const pwd_opt = getEnv(environ, "PWD") orelse getProcEnviron("PWD", &pwd_buf);

    var home_buf: [4096]u8 = undefined;
    const home_opt = getEnv(environ, "HOME") orelse getProcEnviron("HOME", &home_buf);

    var it = std.mem.splitScalar(u8, res.stdout, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r ");
        if (line.len == 0) continue;

        // Skip current working directory
        if (pwd_opt) |pwd| {
            if (std.mem.eql(u8, line, pwd)) continue;
        }

        var cand_buf: [4096]u8 = undefined;
        var cand: []const u8 = line;

        // If inside current working directory, show path relative to pwd
        if (pwd_opt) |pwd| {
            if (std.mem.startsWith(u8, line, pwd) and line.len > pwd.len) {
                const rel = line[pwd.len..];
                if (rel[0] == '/') {
                    cand = rel[1..];
                }
            } else if (!std.mem.startsWith(u8, token, "/") and home_opt != null and std.mem.startsWith(u8, line, home_opt.?)) {
                const rel = line[home_opt.?.len..];
                if (rel.len == 0 or rel[0] == '/') {
                    cand = std.fmt.bufPrint(&cand_buf, "~{s}", .{rel}) catch line;
                }
            }
        } else if (!std.mem.startsWith(u8, token, "/") and home_opt != null and std.mem.startsWith(u8, line, home_opt.?)) {
            const rel = line[home_opt.?.len..];
            if (rel.len == 0 or rel[0] == '/') {
                cand = std.fmt.bufPrint(&cand_buf, "~{s}", .{rel}) catch line;
            }
        }

        var final_cand: []const u8 = cand;
        var with_slash_buf: [4096]u8 = undefined;
        if (cand.len > 0 and cand[cand.len - 1] != '/') {
            final_cand = std.fmt.bufPrint(&with_slash_buf, "{s}/", .{cand}) catch continue;
        }

        if (std.mem.eql(u8, final_cand, token)) continue;
        addCandidate(allocator, candidates, final_cand);
    }
}

pub fn collectCompletionsWithEnv(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    command_cache_opt: ?*const CommandCache,
    candidates: *std.array_list.AlignedManaged([]const u8, null),
    line: []const u8,
    cursor_pos: usize,
) void {
    const pt = @min(cursor_pos, line.len);
    const start = findCompletionStart(line, pt);
    const token = line[start..pt];
    const prefix = line[0..pt];

    if (token.len > 0 and token[0] == '$') {
        const var_prefix = token[1..];
        const COMMON_ENV_VARS = [_][]const u8{
            "HOME", "PATH", "USER", "SHELL", "TERM", "PWD", "EDITOR", "VISUAL", "LANG", "LC_ALL", "TMPDIR", "HOSTNAME", "LOGNAME", "SHLVL", "HISTFILE",
        };
        for (COMMON_ENV_VARS) |var_name| {
            if (std.mem.startsWith(u8, var_name, var_prefix) or std.ascii.startsWithIgnoreCase(var_name, var_prefix)) {
                if (getEnv(environ, var_name) != null) {
                    var var_buf: [256]u8 = undefined;
                    const full_var = std.fmt.bufPrint(&var_buf, "${s}", .{var_name}) catch continue;
                    addCandidate(allocator, candidates, full_var);
                }
            }
        }
        if (candidates.items.len > 0) return;
    }

    const pos_info = getCommandPositionInfo(prefix);

    if (pos_info.is_command_position) {
        if (token.len > 0 and (token[0] == '.' or token[0] == '/' or token[0] == '~')) {
            expandPathNative(allocator, environ, candidates, token, false);
            if (candidates.items.len > 0) return;
        } else {
            for (BUILTINS_AND_KEYWORDS) |kw| {
                if (std.mem.startsWith(u8, kw, token)) addCandidate(allocator, candidates, kw);
            }
            if (command_cache_opt) |cc| {
                const idx = std.sort.lowerBound([]const u8, cc.commands.items, token, comparePrefix);
                var i = idx;
                while (i < cc.commands.items.len) : (i += 1) {
                    const cmd = cc.commands.items[i];
                    if (!std.mem.startsWith(u8, cmd, token)) break;
                    addCandidate(allocator, candidates, cmd);
                }
            }
            if (candidates.items.len > 0) return;
        }
    }

    if (std.mem.eql(u8, pos_info.prefix, "z") or std.mem.eql(u8, pos_info.prefix, "zi")) {
        expandPathNative(allocator, environ, candidates, token, true);
        if (candidates.items.len > 0) return;

        collectZoxideCompletions(allocator, io, environ, candidates, token);
        if (candidates.items.len > 0) return;
    }

    if (std.mem.eql(u8, pos_info.prefix, "cd") or
        std.mem.eql(u8, pos_info.prefix, "pushd") or
        std.mem.eql(u8, pos_info.prefix, "rmdir") or
        std.mem.eql(u8, pos_info.prefix, "builtin cd"))
    {
        expandPathNative(allocator, environ, candidates, token, true);
        if (candidates.items.len > 0) return;
    }

    // If the token is an explicit relative/absolute/home path (e.g. ./, ../, ~/, /),
    // resolve it directly using fast native path completion without spawning external shells.
    if (token.len > 0 and (token[0] == '/' or token[0] == '~' or std.mem.startsWith(u8, token, "./") or std.mem.startsWith(u8, token, "../"))) {
        expandPathNative(allocator, environ, candidates, token, false);
        if (candidates.items.len > 0) return;
    }

    // Fast-path for common file-oriented tools (cat, vim, nano, less, rm, cp, mv, etc.)
    // When completing a non-flag argument, native path completion is instantaneous and
    // avoids spawning bash.
    if (isFileOrientedCommand(pos_info.prefix)) {
        if (token.len == 0 or token[0] != '-') {
            expandPathNative(allocator, environ, candidates, token, false);
            return;
        }
    }

    collectBashCompletions(allocator, io, candidates, line, pt);
    if (candidates.items.len > 0) return;

    expandPathNative(allocator, environ, candidates, token, false);
}

pub fn collectCompletions(
    allocator: std.mem.Allocator,
    io: std.Io,
    candidates: *std.array_list.AlignedManaged([]const u8, null),
    line: []const u8,
    pt: usize,
) void {
    collectCompletionsWithEnv(allocator, io, std.process.Environ.empty, null, candidates, line, pt);
}

test "findCompletionStart" {
    try std.testing.expectEqual(@as(usize, 3), findCompletionStart("cd own", 6));
    try std.testing.expectEqual(@as(usize, 3), findCompletionStart("cd ~/own", 8));
    try std.testing.expectEqual(@as(usize, 3), findCompletionStart("cd My\\ Folder/own", 16));
}

test "collectCompletions fuzzy and case-insensitive navigation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    {
        var candidates = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer {
            for (candidates.items) |c| allocator.free(c);
            candidates.deinit();
        }
        collectCompletions(allocator, io, &candidates, "cd ~/own", 8);
        var found = false;
        for (candidates.items) |c| {
            if (std.mem.indexOf(u8, c, "Downloads/") != null) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    {
        var candidates = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer {
            for (candidates.items) |c| allocator.free(c);
            candidates.deinit();
        }
        collectCompletions(allocator, io, &candidates, "cd ~/dow", 8);
        var found = false;
        for (candidates.items) |c| {
            if (std.mem.indexOf(u8, c, "Downloads/") != null) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    {
        var candidates = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer {
            for (candidates.items) |c| allocator.free(c);
            candidates.deinit();
        }
        collectCompletions(allocator, io, &candidates, "cat src/com", 11);
        var found = false;
        for (candidates.items) |c| {
            if (std.mem.eql(u8, c, "src/completion.zig")) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    {
        var candidates = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer {
            for (candidates.items) |c| allocator.free(c);
            candidates.deinit();
        }
        collectCompletions(allocator, io, &candidates, "git ", 4);
        var found_add = false;
        var found_commit = false;
        var found_file = false;
        for (candidates.items) |c| {
            const trimmed = std.mem.trimEnd(u8, c, " ");
            if (std.mem.eql(u8, trimmed, "add")) found_add = true;
            if (std.mem.eql(u8, trimmed, "commit")) found_commit = true;
            if (std.mem.eql(u8, c, "build.zig") or std.mem.eql(u8, c, "src/")) found_file = true;
        }
        try std.testing.expect(found_add);
        try std.testing.expect(found_commit);
        try std.testing.expect(!found_file);
    }

    {
        var candidates = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer {
            for (candidates.items) |c| allocator.free(c);
            candidates.deinit();
        }
        collectCompletions(allocator, io, &candidates, "git ad", 6);
        var found_add = false;
        for (candidates.items) |c| {
            const trimmed = std.mem.trimEnd(u8, c, " ");
            if (std.mem.eql(u8, trimmed, "add")) found_add = true;
        }
        try std.testing.expect(found_add);
    }

    {
        var candidates = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer {
            for (candidates.items) |c| allocator.free(c);
            candidates.deinit();
        }
        collectCompletions(allocator, io, &candidates, "nvim ", 5);
        var found_build = false;
        var found_src = false;
        for (candidates.items) |c| {
            if (std.mem.eql(u8, c, "build.zig")) found_build = true;
            if (std.mem.eql(u8, c, "src/")) found_src = true;
        }
        try std.testing.expect(found_build);
        try std.testing.expect(found_src);
    }

    {
        var candidates = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer {
            for (candidates.items) |c| allocator.free(c);
            candidates.deinit();
        }
        collectCompletions(allocator, io, &candidates, "cat ", 4);
        var found_build = false;
        var found_src = false;
        for (candidates.items) |c| {
            if (std.mem.eql(u8, c, "build.zig")) found_build = true;
            if (std.mem.eql(u8, c, "src/")) found_src = true;
        }
        try std.testing.expect(found_build);
        try std.testing.expect(found_src);
    }

    {
        var candidates = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer {
            for (candidates.items) |c| allocator.free(c);
            candidates.deinit();
        }
        collectCompletions(allocator, io, &candidates, "cd ", 3);
        var found_src = false;
        var found_file = false;
        for (candidates.items) |c| {
            if (std.mem.eql(u8, c, "src/")) found_src = true;
            if (std.mem.eql(u8, c, "build.zig")) found_file = true;
        }
        try std.testing.expect(found_src);
        try std.testing.expect(!found_file);
    }
}

test "getCommandPositionInfo" {
    {
        const res = getCommandPositionInfo("g");
        try std.testing.expect(res.is_command_position);
        try std.testing.expectEqualStrings("g", res.prefix);
    }
    {
        const res = getCommandPositionInfo("   grep");
        try std.testing.expect(res.is_command_position);
        try std.testing.expectEqualStrings("grep", res.prefix);
    }
    {
        const res = getCommandPositionInfo("git ");
        try std.testing.expect(!res.is_command_position);
        try std.testing.expectEqualStrings("git", res.prefix);
    }
    {
        const res = getCommandPositionInfo("cat file.txt | gr");
        try std.testing.expect(res.is_command_position);
        try std.testing.expectEqualStrings("gr", res.prefix);
    }
    {
        const res = getCommandPositionInfo("cat file.txt |   wc");
        try std.testing.expect(res.is_command_position);
        try std.testing.expectEqualStrings("wc", res.prefix);
    }
    {
        const res = getCommandPositionInfo("echo 'a | b' | gr");
        try std.testing.expect(res.is_command_position);
        try std.testing.expectEqualStrings("gr", res.prefix);
    }
    {
        const res = getCommandPositionInfo("cd foo && mk");
        try std.testing.expect(res.is_command_position);
        try std.testing.expectEqualStrings("mk", res.prefix);
    }
    {
        const res = getCommandPositionInfo("false || ec");
        try std.testing.expect(res.is_command_position);
        try std.testing.expectEqualStrings("ec", res.prefix);
    }
    {
        const res = getCommandPositionInfo("sudo gr");
        try std.testing.expect(res.is_command_position);
        try std.testing.expectEqualStrings("gr", res.prefix);
    }
    {
        const res = getCommandPositionInfo("sudo -u root gr");
        try std.testing.expect(res.is_command_position);
        try std.testing.expectEqualStrings("gr", res.prefix);
    }
    {
        const res = getCommandPositionInfo("cat gr");
        try std.testing.expect(!res.is_command_position);
        try std.testing.expectEqualStrings("cat", res.prefix);
    }
}

test "findPathMatch in local directory" {
    var buf: [512]u8 = undefined;
    const environ = std.process.Environ.empty;
    const res = findPathMatch(environ, "src/com", &buf);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("pletion.zig", res.?);
}

test "findArgumentPathMatch" {
    var buf: [512]u8 = undefined;
    const environ = std.process.Environ.empty;
    const res = findArgumentPathMatch(environ, "cat src/com", &buf);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("pletion.zig", res.?);
}

test "CommandCache builtin and PATH matching" {
    const allocator = std.testing.allocator;
    var cache = CommandCache.init(allocator);
    defer cache.deinit();

    cache.load(std.process.Environ.empty);
    try std.testing.expect(cache.commands.items.len > 0);

    const git_match = cache.findMatch("gi");
    try std.testing.expect(git_match != null);
    try std.testing.expectEqualStrings("git", git_match.?);

    const grep_match = cache.findMatch("gr");
    try std.testing.expect(grep_match != null);
    try std.testing.expectEqualStrings("grep", grep_match.?);

    const cd_match = cache.findMatch("c");
    try std.testing.expect(cd_match != null);

    const echo_match = cache.findMatch("ec");
    try std.testing.expect(echo_match != null);
    try std.testing.expectEqualStrings("echo", echo_match.?);
}

test "collectZoxideCompletions test" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var candidates = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer {
        for (candidates.items) |c| allocator.free(c);
        candidates.deinit();
    }
    collectZoxideCompletions(allocator, io, std.process.Environ.empty, &candidates, "");
}
