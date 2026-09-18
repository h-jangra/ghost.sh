#!/usr/bin/env bash
# Ghost shell frontend with compiled binary

_GHOST_BIN="$(dirname "${BASH_SOURCE[0]}")/ghost"

shopt -s autocd          # Auto-cd into directories
shopt -s cdspell         # Correct directory typos
shopt -s checkwinsize    # Update terminal dimensions
shopt -s histappend      # Append command history
shopt -s cmdhist         # Save multiline commands
shopt -s lithist         # Preserve history newlines
shopt -s direxpand       # Expand directory completion
shopt -s cdable_vars     # Allow variables as directories
shopt -s expand_aliases  # Enable aliases
shopt -s checkjobs       # Warn about running jobs
shopt -s globstar        # Enable recursive ** globbing
shopt -s nocaseglob      # Case-insensitive globbing

_ghost_run_prompt_command() {
    local _ghost_last_status=$1
    if [[ "${PROMPT_COMMAND@a}" == *a* ]]; then
        local _ghost_hook
        for _ghost_hook in "${PROMPT_COMMAND[@]}"; do
            [[ "$_ghost_hook" =~ ^[[:space:]]*_ghost_readline_hook[[:space:]]*$ ]] && continue
            (exit "$_ghost_last_status")
            eval "$_ghost_hook"
            _ghost_last_status=$?
        done
    elif [[ -n "${PROMPT_COMMAND:-}" ]]; then
        (exit "$_ghost_last_status")
        eval "$PROMPT_COMMAND"
        _ghost_last_status=$?
    fi
    return "$_ghost_last_status"
}

_ghost_readline_hook() {
    # If binary is not available or terminal not interactive, fall back to standard readline
    if ! command -v "$_GHOST_BIN" >/dev/null 2>&1 || [[ ! -t 0 || ! -t 1 || ! -r /dev/tty ]]; then
        return
    fi

    # Recursion guard: prevent re-entering loop if PROMPT_COMMAND invokes this hook
    if [[ -n "${_GHOST_ACTIVE:-}" ]]; then
        return "$?"
    fi
    local _GHOST_ACTIVE=1
    local _ghost_last_status=$?

    local hist_file="${HISTFILE:-$HOME/.bash_history}"
    local tmp_out
    if [[ -d /dev/shm && -w /dev/shm ]]; then
        tmp_out="/dev/shm/ghost_out_$$"
    else
        tmp_out="/tmp/ghost_out_$$"
    fi

    while true; do
        # Run prompt commands (e.g. zoxide, direnv, starship, PS1 generators)
        _ghost_run_prompt_command "$_ghost_last_status"
        _ghost_last_status=$?

        # Flush current session history to disk so binary can access the latest commands
        history -a 2>/dev/null

        local prompt_expanded
        (exit "$_ghost_last_status")
        prompt_expanded="${PS1@P}"

        # Run binary with full TTY ownership
        "$_GHOST_BIN" --prompt "$prompt_expanded" --histfile "$hist_file" --output "$tmp_out" </dev/tty >/dev/tty 2>/dev/tty
        local status=$?

        if (( status == 0 )) && [[ -f "$tmp_out" ]]; then
            local cmd
            cmd=$(<"$tmp_out")
            > "$tmp_out"
            if [[ -n "$cmd" ]]; then
                history -s "$cmd" 2>/dev/null
                history -a 2>/dev/null
                eval "$cmd"
                _ghost_last_status=$?
            else
                _ghost_last_status=0
            fi
        elif (( status == 1 )); then
            # Ctrl-D on empty line (EOF) -> exit shell immediately
            rm -f "$tmp_out" 2>/dev/null
            exit 0
        elif (( status == 130 )); then
            _ghost_last_status=130
            > "$tmp_out"
            continue
        else
            rm -f "$tmp_out" 2>/dev/null
            break
        fi
    done
    rm -f "$tmp_out" 2>/dev/null
}

if [[ "${PROMPT_COMMAND@a}" == *a* ]]; then
    _ghost_found=0
    for _ghost_cmd in "${PROMPT_COMMAND[@]}"; do
        [[ "$_ghost_cmd" == "_ghost_readline_hook" ]] && { _ghost_found=1; break; }
    done
    (( !_ghost_found )) && PROMPT_COMMAND+=(_ghost_readline_hook)
    unset _ghost_found _ghost_cmd
else
    [[ "${PROMPT_COMMAND:-}" != *"_ghost_readline_hook"* ]] && PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }_ghost_readline_hook"
fi
