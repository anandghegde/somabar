#!/bin/sh
# Reports a coding agent's state to Somabar's notch (N11), and can ask the notch to answer a
# permission prompt (P2).
#
# Usage, from a Claude Code hook (the hook's JSON arrives on stdin):
#   somabar-agent-hook.sh working|needsYou|done|ended
#   somabar-agent-hook.sh ask          # from a PermissionRequest hook
#
# Sends one NDJSON line to ~/Library/Application Support/Somabar/agent.sock, which exists only
# while Settings > Advanced > "Listen for coding agents" is on. Reports are silent, never block
# the agent (the send runs in the background) and always exit 0, so a missing Somabar changes
# nothing.
#
# "ask" sends a request and waits, at most SOMABAR_AGENT_WAIT seconds (75), for Somabar's one
# reply line: {"id":"…","decision":"allow|deny|ask"}. Allow and deny are printed as Claude Code's
# PermissionRequest (or PreToolUse) decision JSON. Anything else -- "ask", no answer, no socket,
# "Answer permission prompts" off -- prints nothing, and the agent asks in its terminal as usual.
# It never allows on its own.

state="${1:-working}"
sock="${SOMABAR_AGENT_SOCKET:-$HOME/Library/Application Support/Somabar/agent.sock}"
[ -S "$sock" ] || exit 0

# The terminal app to bring forward: its bundle ID where macOS set it, else TERM_PROGRAM.
terminal="${__CFBundleIdentifier:-${TERM_PROGRAM:-}}"

# What the tool is about to do, cut to 200 characters: the command, file, URL or pattern, else
# its whole input as JSON (MCP tools).
detail_filter='(.tool_input // {}) as $ti
    | ($ti.command // $ti.file_path // $ti.url // $ti.pattern // $ti.path
        // (if $ti == {} then "" else ($ti | tojson) end))
    | tostring | .[0:200]'

if [ "$state" != "ask" ]; then
    line=$(/usr/bin/jq -c \
        --arg state "$state" \
        --arg terminal "$terminal" \
        "($detail_filter) as \$what | {
            session: (.session_id // \"default\"),
            project: (.cwd // \"\"),
            state: \$state,
            terminal: \$terminal,
            detail: (
                if .tool_name then
                    .tool_name + (if \$what == \"\" then \"\" else \": \" + \$what end)
                else (.message // \"\") end)
        }" 2>/dev/null) || exit 0
    [ -n "$line" ] || exit 0
    (printf '%s\n' "$line" | /usr/bin/nc -U -w 2 "$sock" >/dev/null 2>&1 &)
    exit 0
fi

# --- ask: wait for Allow or Deny -------------------------------------------------------------

input=$(cat)
id="$$-$(date +%s)"
event=$(printf '%s' "$input" | /usr/bin/jq -r '.hook_event_name // "PermissionRequest"' 2>/dev/null)
line=$(printf '%s' "$input" | /usr/bin/jq -c \
    --arg id "$id" \
    --arg terminal "$terminal" \
    "{
        request: \$id,
        session: (.session_id // \"default\"),
        project: (.cwd // \"\"),
        terminal: \$terminal,
        tool: (.tool_name // \"\"),
        detail: ($detail_filter)
    }" 2>/dev/null) || exit 0
[ -n "$line" ] || exit 0

# nc's input must stay open while it waits (a closed input half-closes the socket, which Somabar
# reads as the hook having gone), so it reads from a FIFO this script holds open, and the reply
# is watched for in a file. If this script dies, the FIFO closes and Somabar drops the prompt.
dir=$(mktemp -d "${TMPDIR:-/tmp}/somabar-hook.XXXXXX") || exit 0
ncpid=
cleanup() {
    exec 3>&-
    [ -n "$ncpid" ] && kill "$ncpid" 2>/dev/null
    rm -rf "$dir"
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP
trap '' PIPE
mkfifo "$dir/in" || exit 0
/usr/bin/nc -U "$sock" <"$dir/in" >"$dir/out" 2>/dev/null &
ncpid=$!
exec 3>"$dir/in"
printf '%s\n' "$line" >&3

wait_ticks=$(( ${SOMABAR_AGENT_WAIT:-75} * 5 ))
tick=0
while [ "$tick" -lt "$wait_ticks" ]; do
    [ -s "$dir/out" ] && break
    kill -0 "$ncpid" 2>/dev/null || break
    sleep 0.2
    tick=$((tick + 1))
done

decision=$(head -n 1 "$dir/out" 2>/dev/null \
    | /usr/bin/jq -r --arg id "$id" 'select(.id == $id) | .decision' 2>/dev/null)

case "$decision" in
    allow|deny) ;;
    *) exit 0 ;;
esac

if [ "$event" = "PreToolUse" ]; then
    /usr/bin/jq -cn --arg decision "$decision" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: $decision,
            permissionDecisionReason: (if $decision == "allow" then "Allowed from the Somabar notch" else "Denied from the Somabar notch" end)
        }
    }'
elif [ "$decision" = "allow" ]; then
    /usr/bin/jq -cn '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"}}}'
else
    /usr/bin/jq -cn '{hookSpecificOutput: {hookEventName: "PermissionRequest",
        decision: {behavior: "deny", message: "Denied from the Somabar notch"}}}'
fi
exit 0
