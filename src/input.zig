const std = @import("std");
const Term = @import("terminal.zig").Term;

pub const Key = union(enum) {
    char: u21,
    up,
    down,
    left,
    right,
    home,
    end,
    backspace,
    delete,
    tab,
    shift_tab,
    enter,
    escape,
    alt_f,
    alt_b,
    alt_d,
    alt_dot,
    alt_underscore,
    alt_caret,
    ctrl_a,
    ctrl_b,
    ctrl_c,
    ctrl_d,
    ctrl_e,
    ctrl_f,
    ctrl_g,
    ctrl_k,
    ctrl_l,
    ctrl_r,
    ctrl_t,
    ctrl_u,
    ctrl_w,
    ctrl_x_e,
    paste_start,
    paste_end,
    unknown,
};

pub fn readKey(term: *Term) Key {
    const b0 = term.readByte(-1) orelse return .unknown;

    if (b0 == 0x1b) {
        // Handle ESC ESC prefix (some terminals send Alt+Arrow as ESC ESC [ ...)
        var esc_retries: usize = 0;
        while (esc_retries < 8) : (esc_retries += 1) {
            const b1 = term.readByte(20) orelse return .escape;
            if (b1 == 0x1b) continue;
            if (b1 == '[' or b1 == 'O') return readCsi(term);
            return altKeyFromByte(b1);
        }
        return .escape;
    }

    return switch (b0) {
        1 => .ctrl_a,
        2 => .ctrl_b,
        3 => .ctrl_c,
        4 => .ctrl_d,
        5 => .ctrl_e,
        6 => .ctrl_f,
        7 => .ctrl_g,
        8, 127 => .backspace,
        9 => .tab,
        10, 13 => .enter,
        11 => .ctrl_k,
        12 => .ctrl_l,
        14 => .down,
        16 => .up,
        18 => .ctrl_r,
        20 => .ctrl_t,
        21 => .ctrl_u,
        23 => .ctrl_w,
        24 => blk: {
            if (term.readByte(100)) |next_b| {
                if (next_b == 5 or next_b == 'e' or next_b == 'E') break :blk .ctrl_x_e;
            }
            break :blk .unknown;
        },
        32...126 => .{ .char = b0 },
        else => decodeUtf8(b0, term),
    };
}

fn altKeyFromByte(b: u8) Key {
    return switch (std.ascii.toLower(b)) {
        'f' => .alt_f,
        'b' => .alt_b,
        'd' => .alt_d,
        '.', '>' => .alt_dot,
        '_', '-' => .alt_underscore,
        '^' => .alt_caret,
        8, 127 => .ctrl_w,
        else => .escape,
    };
}

fn decodeUtf8(b0: u8, term: *Term) Key {
    if (b0 < 0x80) return .unknown;
    const seq_len = std.unicode.utf8ByteSequenceLength(b0) catch return .unknown;
    var utf8_buf: [4]u8 = undefined;
    utf8_buf[0] = b0;
    var i: usize = 1;
    while (i < seq_len) : (i += 1) {
        utf8_buf[i] = term.readByte(20) orelse return .unknown;
    }
    const cp = std.unicode.utf8Decode(utf8_buf[0..seq_len]) catch return .unknown;
    return .{ .char = cp };
}

const max_csi_params = 8;

/// Read and decode a full CSI/SS3 sequence, always consuming to its final byte
/// so unrecognized sequences never leak remaining bytes into the input buffer.
fn readCsi(term: *Term) Key {
    var params: [max_csi_params]u32 = undefined;
    var np: usize = 0; // stored parameter count
    var cur: u32 = 0;
    var has_digits = false;
    var subfield = false; // skipping kitty sub-field digits after ':'
    var final_byte: u8 = 0;

    var iters: usize = 0;
    while (iters < 64) : (iters += 1) {
        const b = term.readByte(20) orelse return .escape;
        switch (b) {
            '0'...'9' => {
                if (!subfield) {
                    cur = cur * 10 + (b - '0');
                    if (cur > 999_999) return .escape;
                    has_digits = true;
                }
            },
            // Kitty keyboard protocol sub-fields: key:alt-code / mods:event-type
            ':' => {
                storeParam(&params, &np, cur, has_digits);
                cur = 0;
                has_digits = false;
                subfield = true;
            },
            ';' => {
                if (subfield) {
                    subfield = false;
                } else {
                    storeParam(&params, &np, cur, has_digits);
                }
                cur = 0;
                has_digits = false;
            },
            // Other intermediates / private prefixes ('?', '>', ' ', ...) — keep consuming
            0x20...0x2f, 0x3c...0x3f => {},
            // Final byte terminates the sequence
            0x40...0x7e => {
                storeParam(&params, &np, cur, has_digits);
                final_byte = b;
                break;
            },
            // Unexpected control byte — abandon the sequence
            else => return .escape,
        }
    }
    if (final_byte == 0) return .escape;
    if (np == 0) return .unknown;

    switch (final_byte) {
        'A' => return .up,
        'B' => return .down,
        'H' => return .home,
        'F' => return .end,
        'Z' => return .shift_tab,
        'C' => {
            // Preserve legacy behavior: Ctrl/Alt+Right (`ESC[1;5C`, `ESC[5;3C`, `ESC[5C`)
            const flags = modsFlags(lastParam(params, np));
            if (flags != 0 or (np >= 1 and params[0] == 5)) return .alt_f;
            return .right;
        },
        'D' => {
            const flags = modsFlags(lastParam(params, np));
            if (flags != 0 or (np >= 1 and params[0] == 5)) return .alt_b;
            return .left;
        },
        '~' => return homeEndOrFtilde(params[0]),
        'u' => {
            // xterm modifyOtherKeys=2 form: `ESC [ 27 ; mods ; char u`
            if (np >= 3 and params[0] == 27) return decodeCsiU(params[2], params[1]);
            return decodeCsiU(params[0], lastMod(params, np));
        },
        // X10 mouse events carry 2-3 raw trailing bytes; drain them
        'M' => {
            _ = term.readByte(20);
            _ = term.readByte(20);
            _ = term.readByte(20);
            return .unknown;
        },
        else => return .unknown,
    }
}

fn storeParam(params: *[max_csi_params]u32, np: *usize, value: u32, present: bool) void {
    if (np.* < max_csi_params) params[np.*] = if (present) value else 0;
    np.* += 1;
}

/// Last stored numeric parameter, or 0 when absent.
fn lastMod(params: [max_csi_params]u32, np: usize) u32 {
    if (np >= 2) return params[@min(np - 1, max_csi_params - 1)];
    return 0;
}

fn lastParam(params: [max_csi_params]u32, np: usize) u32 {
    if (np >= 1) return params[@min(np - 1, max_csi_params - 1)];
    return 0;
}

fn homeEndOrFtilde(code: u32) Key {
    return switch (code) {
        1, 7 => .home,
        3 => .delete,
        4, 8 => .end,
        200 => .paste_start,
        201 => .paste_end,
        else => .unknown,
    };
}

/// Kitty protocol modifiers: value is `1 + flags` (bit 0 shift, bit 1 alt, bit 4 ctrl);
/// lock-key bits (e.g. 133) are masked off.
fn modsFlags(mods: u32) u8 {
    if (mods == 0) return 0;
    return @intCast((mods - 1) & 0x3F);
}

/// Decode a CSI-u sequence (`ESC [ key ; mods u`, kitty keyboard protocol or
/// xterm modifyOtherKeys) into a Key.
fn decodeCsiU(key: u32, mods: u32) Key {
    const flags = modsFlags(mods);
    const alt = flags & 2 != 0;
    const ctrl = flags & 4 != 0;
    const shift = flags & 1 != 0;

    // Kitty functional key codes (>= 57344, "report all keys" mode)
    if (key >= 57344) {
        return switch (key) {
            57344 => .escape,
            57345 => .enter,
            57346 => if (shift) .shift_tab else .tab,
            57347 => .backspace,
            57349 => .delete,
            57350 => if (alt or ctrl) .alt_b else .left,
            57351 => if (alt or ctrl) .alt_f else .right,
            57352 => .up,
            57353 => .down,
            57356 => .home,
            57357 => .end,
            else => .unknown, // Insert, PgUp/PgDn, F1-F64, lock keys, ...
        };
    }

    if (ctrl) {
        return switch (key | 0x20) {
            'a' => .ctrl_a,
            'b' => .ctrl_b,
            'c' => .ctrl_c,
            'd' => .ctrl_d,
            'e' => .ctrl_e,
            'f' => .ctrl_f,
            'g' => .ctrl_g,
            'h' => .backspace,
            'i' => .tab,
            'j' => .enter,
            'k' => .ctrl_k,
            'l' => .ctrl_l,
            'm' => .enter,
            'n' => .down,
            'p' => .up,
            'r' => .ctrl_r,
            't' => .ctrl_t,
            'u' => .ctrl_u,
            'w' => .ctrl_w,
            else => .unknown,
        };
    }

    if (alt) {
        return switch (key | 0x20) {
            'f' => .alt_f,
            'b' => .alt_b,
            'd' => .alt_d,
            '.', '>' => .alt_dot,
            '_', '-' => .alt_underscore,
            '^' => .alt_caret,
            else => .unknown,
        };
    }

    return switch (key) {
        9 => if (shift) .shift_tab else .tab, // e.g. Shift+Tab = `ESC [ 9 ; 2 u`
        10, 13 => .enter,
        27 => .escape,
        8, 127 => .backspace,
        else => blk: {
            if (key >= 32 and key <= 0x10FFFF) break :blk Key{ .char = @intCast(key) };
            break :blk .unknown;
        },
    };
}
