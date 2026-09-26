#!/bin/sh
# Reports a coding agent's state to Somabar's notch (N11).
#
# Usage, from a Claude Code hook (the hook's JSON arrives on stdin):
#   somabar-agent-hook.sh working|needsYou|done|ended
#
# Sends one NDJSON line to ~/Library/Application Support/Somabar/agent.sock, which exists only
# while Settings > Advanced > "Listen for coding agents" is on. Silent, never blocks the agent
# (the send runs in the background) and always exits 0, so a missing Somabar changes nothing.

state="${1:-working}"
sock="${SOMABAR_AGENT_SOCKET:-$HOME/Library/Application Support/Somabar/agent.sock}"
[ -S "$sock" ] || exit 0

# The terminal app to bring forward: its bundle ID where macOS set it, else TERM_PROGRAM.
terminal="${__CFBundleIdentifier:-${TERM_PROGRAM:-}}"

line=$(/usr/bin/jq -c \
    --arg state "$state" \
    --arg terminal "$terminal" \
    '{
        session: (.session_id // "default"),
        project: (.cwd // ""),
        state: $state,
        terminal: $terminal,
        detail: (
            if .tool_name then
                .tool_name + (
                    (.tool_input.command // .tool_input.file_path // .tool_input.url // "")
                    | tostring | .[0:160]
                    | if . == "" then "" else ": " + . end)
            else (.message // "") end)
    }' 2>/dev/null) || exit 0
[ -n "$line" ] || exit 0

(printf '%s\n' "$line" | /usr/bin/nc -U -w 2 "$sock" >/dev/null 2>&1 &)
exit 0
