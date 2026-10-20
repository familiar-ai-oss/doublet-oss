#!/usr/bin/env bash
# Every shell command Claude and the workers run goes through here (CLAUDE_CODE_SHELL_PREFIX, set in
# duet-hub.service). Claude Code passes the whole command as the last argument.
#
# The command runs in a systemd scope of its own, in duet-commands.slice, outside the hub's service:
# - a command that runs away with memory is stopped at DUET_COMMAND_MEMORY_MAX (32G), and the slice holds all of them
#   to 48G, so it can't take the hub machine (and the hub) down. On 2026-10-19 a model-checking walk grew to 69 GB, the kernel
#   killed it, and systemd stopped the whole hub with it, ending Claude's session mid-question;
# - restarting the hub no longer kills the long runs Claude started.
# Without the user's systemd (no bus), the command runs as before.
cmd="${!#}"
bus="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus"
if [ -S "$bus" ] && command -v systemd-run >/dev/null 2>&1; then
  exec systemd-run --user --scope --quiet --collect --slice=duet-commands.slice \
    -p MemoryMax="${DUET_COMMAND_MEMORY_MAX:-32G}" -p MemorySwapMax=0 \
    -- bash -c "$cmd"
fi
exec bash -c "$cmd"
