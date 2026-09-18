# Ghost

Ghost is a lightweight interactive frontend for Bash written in Zig. It replaces Bash's line editor with history-based ghost suggestions, interactive grid completions, and UTF-8 line editing while keeping Bash as the underlying shell.

![Demo](assets/demo.gif)

## Features

* **Ghost suggestions** — Inline autosuggestions from command history (`→` / `End` to accept fully, `Alt`+`F` for next word).
* **Interactive completions** — Multi-column menu navigable with arrow keys, `Tab`, and `Shift`+`Tab`.
* **Fuzzy & case-insensitive navigation** — Smart path resolution supporting case-insensitive prefix, substring (e.g. `cd own` → `Downloads/`), and multi-segment fuzzy matching.
* **Bash programmable completion support** — Works with standard Bash completions (`complete`, `compgen`, `bash-completion`).
* **UTF-8 & wide character support** — Cursor and layout handling for multi-byte, wide, and emoji characters.
* **Bracketed paste** — Pastes multi-line text safely into the buffer.
* **External editor integration** — Edit the current command buffer in `$VISUAL` / `$EDITOR` via `Ctrl`+`X` `E`.

## Installation

Ghost installs both the frontend binary and loader script under `/usr/share/ghost/`:

```text
/usr/share/ghost/
├── ghost
└── ghost.sh
```

### Option A: Prebuilt Binary (Linux x86_64)

Download the prebuilt binary and script from GitHub releases:

```bash
sudo mkdir -p /usr/share/ghost
sudo curl -fsSL https://github.com/h-jangra/ghost.sh/releases/latest/download/ghost-x86_64-linux -o /usr/share/ghost/ghost
sudo curl -fsSL https://raw.githubusercontent.com/h-jangra/ghost.sh/main/ghost.sh -o /usr/share/ghost/ghost.sh
sudo chmod 755 /usr/share/ghost/ghost
sudo chmod 644 /usr/share/ghost/ghost.sh
```

### Option B: Build from Source

**Prerequisites:** [Zig](https://ziglang.org/) and Bash.

```bash
git clone https://github.com/h-jangra/Ghost.sh.git ghost
cd ghost
zig build -Doptimize=ReleaseFast

sudo install -Dm755 zig-out/bin/ghost /usr/share/ghost/ghost
sudo install -Dm644 ghost.sh /usr/share/ghost/ghost.sh
```

### [Bash Only Release](https://github.com/h-jangra/ghost.sh/releases/tag/0.4.0)
Not as smooth as the binary, but available if needed. Source the provided shell files in your `.bashrc`.

### Shell Setup

Add to your `~/.bashrc` and reload shell:

```bash
if [[ -f "/usr/share/ghost/ghost.sh" ]]; then
    source "/usr/share/ghost/ghost.sh"
fi
```

```bash
source ~/.bashrc
```

## Keybindings

### Navigation & Suggestions

| Key | Action |
| --- | --- |
| `←` / `Ctrl`+`B` | Move cursor left |
| `→` / `Ctrl`+`F` | Move cursor right / accept ghost suggestion |
| `Home` / `Ctrl`+`A` | Move cursor to beginning of line |
| `End` / `Ctrl`+`E` | Move cursor to end of line / accept ghost suggestion |
| `Alt`+`B` | Move backward one word |
| `Alt`+`F` | Move forward one word / accept next suggestion word |

### Editing

| Key | Action |
| --- | --- |
| `Backspace` / `Ctrl`+`H` | Delete character backward |
| `Delete` / `Ctrl`+`D` | Delete character forward (when line is non-empty) |
| `Ctrl`+`W` | Delete word backward |
| `Alt`+`D` | Delete word forward |
| `Ctrl`+`U` | Kill line to start |
| `Ctrl`+`K` | Kill line to end |
| `Ctrl`+`T` | Transpose characters |
| `Ctrl`+`X` `E` | Edit command buffer in `$VISUAL` / `$EDITOR` |

### History & Search

| Key | Action |
| --- | --- |
| `↑` / `Ctrl`+`P` | Previous history command |
| `↓` / `Ctrl`+`N` | Next history command |
| `Ctrl`+`R` | Interactive history search (built-in or `GHOST_CTRL_R_COMMAND`) |

### Completion Menu

| Key | Action |
| --- | --- |
| `Tab` / `→` | Next candidate |
| `Shift`+`Tab` / `←` | Previous candidate |
| `↓` / `↑` | Move down / up one row |
| `Enter` | Accept selected candidate |
| `Esc` / `Ctrl`+`C` | Close completion menu |

### Terminal Control

| Key | Action |
| --- | --- |
| `Ctrl`+`C` | Cancel current line and close completion menu |
| `Ctrl`+`D` | Exit shell (when line is empty) |
| `Ctrl`+`L` | Clear screen and re-render prompt |

## Configuration

| Variable | Purpose | Default | Example |
| --- | --- | --- | --- |
| `GHOST_CTRL_R_COMMAND` | Optional command override for `Ctrl`+`R` search | _Unset (uses built-in search)_ | `export GHOST_CTRL_R_COMMAND="fzf --reverse"` |
| `HISTFILE` | History file to load | `~/.bash_history` | `export HISTFILE="$HOME/.bash_history"` |
| `VISUAL` / `EDITOR` | Editor for `Ctrl`+`X` `E` | `nano` (fallback: `vi`) | `export EDITOR="nvim"` |
| `_GHOST_BIN` | Custom path override for `ghost` binary | Auto-detected adjacent to `ghost.sh` or in `PATH` | `export _GHOST_BIN="/custom/path/ghost"` |

### History Search (Ctrl-R)

Pressing `Ctrl`+`R` opens built-in interactive history search (`(reverse-i-search)`). Repeatedly pressing `Ctrl`+`R` cycles matches, `Enter` accepts, and `Esc` / `Ctrl`+`C` / `Ctrl`+`G` cancels.

Setting `GHOST_CTRL_R_COMMAND` overrides built-in search with an external filter command (e.g., `fzf`, `peco`, `sk`), streaming history to `stdin` and inserting the selected command into the buffer:

```bash
export GHOST_CTRL_R_COMMAND="fzf --height=40% --reverse --scheme=history --tiebreak=index"
```

## Bash Completion

Ghost executes Bash completion functions (`complete`, `compgen`, and `bash-completion`) on demand when `Tab` is pressed, incurring no subprocess overhead during normal typing.

## Limitations

* Replaces interactive line editing only; Bash remains the execution environment.
* Requires a POSIX terminal with `/dev/tty` access.
* Does not parse Readline configuration (`~/.inputrc`).
