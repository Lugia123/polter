# This shell script aims to be written in a way where it can't really fail
# or all failure scenarios are handled, so that we never leave the shell in
# a weird state. If you find a way to break this, please report a bug!

function ghostty_restore_xdg_data_dir -d "restore the original XDG_DATA_DIR value"
    # If we don't have our own data dir then we don't need to do anything.
    if not set -q GHOSTTY_SHELL_INTEGRATION_XDG_DIR
        return
    end

    # If the data dir isn't set at all then we don't need to do anything.
    if not set -q XDG_DATA_DIRS
        return
    end

    # We need to do this so that XDG_DATA_DIRS turns into an array.
    set --function --path xdg_data_dirs "$XDG_DATA_DIRS"

    # If our data dir is in the list then remove it.
    if set --function index (contains --index "$GHOSTTY_SHELL_INTEGRATION_XDG_DIR" $xdg_data_dirs)
        set --erase --function xdg_data_dirs[$index]
    end

    # Re-export our data dir
    if set -q xdg_data_dirs[1]
        set --global --export --unpath XDG_DATA_DIRS "$xdg_data_dirs"
    else
        set --erase --global XDG_DATA_DIRS
    end

    set --erase GHOSTTY_SHELL_INTEGRATION_XDG_DIR
end

function ghostty_exit -d "exit the shell integration setup"
    functions -e ghostty_restore_xdg_data_dir
    functions -e ghostty_exit
    exit 0
end

# We always try to restore the XDG data dir
ghostty_restore_xdg_data_dir

# If we aren't interactive or we've already run, don't run.
status --is-interactive || ghostty_exit

# Per-pane history restore (reopening a saved project), independent of the
# fish_prompt-deferred setup below -- replaying history doesn't touch the
# prompt or need any other plugin to run first, it only needs
# `fish_history` (an environment variable Ghostty set before this fish
# process was even exec'd) to already have picked the right named
# session, which it has by the time any script -- this one included --
# gets to run.
#
# fish has no per-pane history file the way bash/zsh do (see
# `CommandHistory.zig`'s doc comment): a session name (`fish_history`)
# selects fish's own storage, and that storage starts out genuinely empty
# for a session name nobody has used before, even if Ghostty captured
# commands for this pane under the old one. `GHOSTTY_HISTORY_RESTORE_FILE`
# is how those get back in -- the plain-text, one-command-per-line file
# `CommandHistory.zig` wrote, replayed one `history append` at a time,
# the same way `fc -p` lets zsh's own history mechanism take over instead
# of this script inventing a second one.
#
# **Only the replay is capped at the most recent 1000 lines, not the
# capture file.** `CommandHistory.zig` still writes and keeps every
# command; this script just doesn't load all of it into a live fish
# session. Losing that distinction reads as "history got truncated",
# which isn't what happens -- the file a project points at is unchanged,
# and re-restoring after raising the cap (or reading the file directly)
# still sees everything.
#
# The cap exists because the cost of `history append` grows faster than
# linearly with how much history is already loaded, not because 1000 is
# some natural fish limit: 500/1000/2000/5000-line replays measured at
# 0.045s/0.088s/0.26s/1.28s respectively. A pane that ran commands for
# months could otherwise make every reopen of its project cost a
# multi-second wait at the first prompt -- paid on every open, for
# history the user is overwhelmingly unlikely to ever press up-arrow far
# enough to reach. 1000 keeps that under the 0.1s mark.
#
# **bash/zsh have no equivalent of this cap and none is planned.** They
# restore by pointing their own `HISTFILE` at the same file and letting
# the shell load it itself (see the `history_restore` doc comment this
# refers to) -- there is no per-line step in this codebase to intervene
# on, so a bash/zsh pane's replay is whatever bash/zsh itself decides
# to load. Don't read fish's cap as "how all three shells behave."
function ghostty_restore_history -d "replay a saved pane's history into this fish session"
    if not set -q GHOSTTY_HISTORY_RESTORE_FILE
        return
    end

    # Read the value, then erase the variable immediately -- before doing
    # any of the actual reading below, not after. A fish (or a script
    # re-exec'ing fish) started from inside this pane would otherwise
    # inherit the same variable and replay the same file a second time,
    # duplicating every entry. Erasing first means even a `history
    # append` that itself spawns something can't see it, not just
    # "anything after this function returns".
    set --function restore_file $GHOSTTY_HISTORY_RESTORE_FILE
    set --erase GHOSTTY_HISTORY_RESTORE_FILE

    # A missing or unreadable file is not an error -- a pane that was
    # saved before it ever ran a command has nothing to restore, and
    # `CommandHistory.zig`'s file only exists once something was
    # captured.
    test -r "$restore_file"; or return

    # `tail` (not reading the whole file into a fish list first) so a
    # file with tens of thousands of lines doesn't cost more than the
    # 1000 lines actually replayed -- the file is never fully loaded
    # into this process just to throw most of it away. `tail`'s output
    # keeps the file's own chronological order (oldest of the kept lines
    # first, newest last), which matters: replaying out of order would
    # still "work" in the sense that every command is there, but the
    # first up-arrow press would land on the wrong one.
    command tail -n 1000 -- "$restore_file" | while read --local restore_line
        builtin history append -- "$restore_line"
    end
end
ghostty_restore_history
functions -e ghostty_restore_history

# We do the full setup on the first prompt render. We do this so that other
# shell integrations that setup the prompt and modify things are able to run
# first. We want to run _last_.
function __ghostty_setup --on-event fish_prompt -d "Setup ghostty integration"
    functions -e __ghostty_setup

    set --local features (string split , $GHOSTTY_SHELL_FEATURES)

    # Parse the fish version for feature detection.
    # Default to 0.0 if version is unavailable or malformed.
    set -l fish_major 0
    set -l fish_minor 0
    if set -q version[1]
        set -l fish_ver (string match -r '(\d+)\.(\d+)' -- $version[1])
        if set -q fish_ver[2]; and test -n "$fish_ver[2]"
            set fish_major "$fish_ver[2]"
        end
        if set -q fish_ver[3]; and test -n "$fish_ver[3]"
            set fish_minor "$fish_ver[3]"
        end
    end

    # Our OSC133A (prompt start) sequence. If we're using Fish >= 4.1
    # then it supports click_events so we enable that.
    set -g __ghostty_prompt_start_mark "\e]133;A\a"
    if test "$fish_major" -gt 4; or test "$fish_major" -eq 4 -a "$fish_minor" -ge 1
        set -g __ghostty_prompt_start_mark "\e]133;A;click_events=1\a"
    end

    if string match -q 'cursor*' -- $features
        set -l cursor 5                                   # blinking bar
        contains cursor:steady $features && set cursor 6  # steady bar

        # Change the cursor to a beam on prompt.
        function __ghostty_set_cursor_beam --on-event fish_prompt -V cursor -d "Set cursor shape"
            if not functions -q fish_vi_cursor_handle
                echo -en "\e[$cursor q"
            end
        end
        function __ghostty_reset_cursor --on-event fish_preexec -d "Reset cursor shape"
            if not functions -q fish_vi_cursor_handle
                echo -en "\e[0 q"
            end
        end
    end

    # Add Ghostty binary to PATH if the path feature is enabled
    if contains path $features; and test -n "$GHOSTTY_BIN_DIR"
        fish_add_path --global --path --append "$GHOSTTY_BIN_DIR"
    end

    # When using sudo shell integration feature, ensure $TERMINFO is set
    # and `sudo` is not already a function or alias
    if contains sudo $features; and test -n "$TERMINFO"; and test file = (type -t sudo 2> /dev/null; or echo "x")
        # Wrap `sudo` command to ensure Ghostty terminfo is preserved
        function sudo -d "Wrap sudo to preserve terminfo"
            set --function sudo_has_sudoedit_flags no
            for arg in $argv
                # Check if argument is '-e' or '--edit' (sudoedit flags)
                if string match -q -- -e "$arg"; or string match -q -- --edit "$arg"
                    set --function sudo_has_sudoedit_flags yes
                    break
                end
                # Check if argument is neither an option nor a key-value pair
                if not string match -r -q -- "^-" "$arg"; and not string match -r -q -- "=" "$arg"
                    break
                end
            end
            if test "$sudo_has_sudoedit_flags" = yes
                command sudo $argv
            else
                command sudo --preserve-env=TERMINFO $argv
            end
        end
    end

    # SSH Integration
    #
    # Wrap `ssh` with `ghostty +ssh` and translate the shell-integration
    # feature flags into command options.
    set -l features (string split ',' -- "$GHOSTTY_SHELL_FEATURES")
    if contains ssh-env $features; or contains ssh-terminfo $features
        function ssh --wraps=ssh --description "SSH wrapper with Ghostty integration"
            set -l features (string split ',' -- "$GHOSTTY_SHELL_FEATURES")
            set -l flags
            contains ssh-env $features; or set -a flags --forward-env=false
            contains ssh-terminfo $features; or set -a flags --terminfo=false
            "$GHOSTTY_BIN_DIR/ghostty" +ssh $flags -- $argv
        end
    end

    # Setup prompt marking
    function __ghostty_mark_prompt_start --on-event fish_prompt --on-event fish_posterror
        # If we never got the output end event, then we need to send it now.
        if test "$__ghostty_prompt_state" != prompt-start
            echo -en "\e]133;D\a"
        end

        set --global __ghostty_prompt_state prompt-start
        echo -en $__ghostty_prompt_start_mark
    end

    function __ghostty_mark_output_start --on-event fish_preexec
        set --global __ghostty_prompt_state pre-exec
        echo -en "\e]133;C\a"

        # Command-line capture (private OSC 60), opt-in via the "history"
        # shell-integration-features member. This writes every command the
        # user types to disk (for per-pane history restore), so unlike the
        # marks above it must not be on by default. $features (the list
        # built near the top of __ghostty_setup) isn't visible here --
        # this function is invoked later by the fish_preexec event
        # dispatcher, not called from __ghostty_setup's own scope -- so
        # $GHOSTTY_SHELL_FEATURES (a real exported env var) is re-split
        # fresh instead.
        if contains history (string split , -- $GHOSTTY_SHELL_FEATURES); and test -n "$GHOSTTY_HISTORY_TOKEN"
            # $argv[1] is the whole typed command as one string, verified
            # against a real backslash-continued multi-line command: fish
            # hands fish_preexec the source text verbatim, embedded
            # newline and all, not re-split per line. C0 controls
            # (newline and tab included) and DEL are not legal inside the
            # OSC 60 payload: the core side drops the entire message if
            # any survive, and an embedded ESC or BEL risks faking the
            # terminator early and truncating everything after it.
            # [[:cntrl:]] is the same class zsh/bash strip for their title
            # feature; replaced with a space rather than deleted so a
            # flattened multi-line command stays word-separated and
            # legible in restored history.
            #
            # GHOSTTY_HISTORY_TOKEN proves this came from a shell reading
            # its own environment, not from output the terminal is merely
            # displaying -- see command_capture.zig's doc comment. It's a
            # second field, before the command, and is never itself run
            # through the [[:cntrl:]] strip above: core issued it, core
            # knows its exact shape.
            set --local hist_cmd (string replace --all --regex '[[:cntrl:]]' ' ' -- $argv[1])
            printf '\e]60;%s;%s\a' "$GHOSTTY_HISTORY_TOKEN" "$hist_cmd"
        end
    end

    function __ghostty_mark_output_end --on-event fish_postexec
        set --global __ghostty_prompt_state post-exec
        echo -en "\e]133;D;$status\a"
    end

    # Report pwd. This is actually built-in to fish but only for terminals
    # that match an allowlist and that isn't us.
    function __update_cwd_osc --on-variable PWD -d 'Notify capable terminals when $PWD changes'
        if status --is-command-substitution || set -q INSIDE_EMACS
            return
        end
        printf \e\]7\;file://%s%s\a $hostname (string escape --style=url $PWD)
    end

    # Enable fish to handle reflow because Ghostty clears the prompt on resize.
    set --global fish_handle_reflow 1

    # Initial calls for first prompt
    if string match -q 'cursor*' -- $features
        __ghostty_set_cursor_beam
    end
    __ghostty_mark_prompt_start
    __update_cwd_osc
end

ghostty_exit
