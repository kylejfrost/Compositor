#!/bin/bash
# Is Compositor's MCP server reachable? Prints one status line, then what to do about it.
#
# Reads the endpoint file Compositor publishes while its server runs
# (~/Library/Application Support/Compositor/mcp/endpoint.json), checks it as the compositor-mcp
# bridge does before trusting it (this user's file, which no one else can change, naming plain
# HTTP to loopback and a process that is a running Compositor), and sends the URL one JSON-RPC
# ping with the access token from the file the endpoint file names. It changes nothing, and
# never prints the token or puts it on a command line.
#
# The token goes only where the running Compositor said it listens. Any other program can
# listen on a loopback port Compositor isn't using (2667 while its server is off, say), another
# user's included, and would collect a token sent there.
#
# Usage: check-compositor.sh [--endpoint-file <path> | --url <url>] [--token-file <path>]
#   --endpoint-file <path>  read this endpoint file instead of the default one
#   --url <url>             ping this endpoint instead, e.g. the URL a client is set up with. It
#                           gets the token only when the default endpoint file, trusted as above,
#                           names exactly this URL (or with --token-file)
#   --token-file <path>     send the access token in this file, whatever the URL
#
# Output: "compositor: <STATUS> ..." then zero or more "fix: ..." and "note: ..." lines.
# STATUS is OK, NOT RUNNING, BROKEN ENDPOINT FILE, UNTRUSTED ENDPOINT FILE, STALE,
# TOKEN UNUSABLE, NOT LISTENING, NO ANSWER, REFUSED <http status>, STARTING or UNEXPECTED.
# Exit status: 0 when the server answered the ping, 1 when it didn't, 2 for bad arguments.

set -u

DEFAULT_PORT=2667
TIMEOUT_SECONDS=3
BRIDGE=/Applications/Compositor.app/Contents/MacOS/compositor-mcp
PING='{"jsonrpc":"2.0","id":"check-compositor","method":"ping"}'

usage() {
    echo "usage: check-compositor.sh [--endpoint-file <path> | --url <url>] [--token-file <path>]" >&2
}

endpoint_file="${HOME:-}/Library/Application Support/Compositor/mcp/endpoint.json"
file_given=0
url=""
token_file=""
while [ $# -gt 0 ]; do
    case "$1" in
        --endpoint-file)
            [ $# -ge 2 ] || { usage; exit 2; }
            endpoint_file=$2; file_given=1; shift 2 ;;
        --url)
            [ $# -ge 2 ] || { usage; exit 2; }
            url=$2; shift 2 ;;
        --token-file)
            [ $# -ge 2 ] || { usage; exit 2; }
            token_file=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "check-compositor: unknown argument $1" >&2; usage; exit 2 ;;
    esac
done
if [ -n "$url" ] && [ $file_given -eq 1 ]; then
    echo "check-compositor: use --endpoint-file or --url, not both" >&2
    usage
    exit 2
fi

status() { echo "compositor: $*"; }
fix() { echo "fix: $*"; }
note() { echo "note: $*"; }

# Ways to start the server, a session start first: the Settings switch is the owner's standing
# decision about who may drive the app, so it comes last and is theirs to flip.
start_fixes() {
    fix "start it for this session, which launches Compositor or signals the open one: echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}' | $BRIDGE"
    fix "or, when Compositor isn't open yet: open -a Compositor --args --mcp  (arguments reach a new launch only)"
    fix "or, if the owner wants it on at every launch, they turn on \"Allow AI agents to control this document\" in Compositor > Settings… (⌘,)"
}

# A top-level value of the endpoint file, or nothing when it has none.
field() {
    plutil -extract "$1" raw -o - "$endpoint_file" 2>/dev/null
}

# Plain HTTP to this Mac's loopback address with a port, and no user part that could name another host.
LOOPBACK_URL='^http://(127\.0\.0\.1|localhost|\[::1\]):[0-9]+(/[^@[:space:]]*)?$'

# Reads the endpoint file into ep_url, ep_pid, ep_version, ep_auth and ep_token_file when it can be trusted:
# this user's own file, which no one else can change, naming plain HTTP to loopback and a pid that is a
# running Compositor. Otherwise returns 1 with problem set to the status and problem_detail to why.
read_endpoint() {
    ep_url="" ep_pid="" ep_version="" ep_auth="" ep_token_file="" problem="" problem_detail=""
    if [ ! -f "$endpoint_file" ]; then
        problem="NOT RUNNING"
        problem_detail="no endpoint file at $endpoint_file; Compositor writes it only while its MCP server runs"
        return 1
    fi
    local mode command
    if [ "$(stat -L -f '%u' "$endpoint_file")" != "$(id -u)" ]; then
        problem="UNTRUSTED ENDPOINT FILE"
        problem_detail="$endpoint_file belongs to another user; the compositor-mcp bridge won't use it"
        return 1
    fi
    mode=$(stat -L -f '%Lp' "$endpoint_file")
    if [ $(( 8#$mode & 8#022 )) -ne 0 ]; then
        problem="UNTRUSTED ENDPOINT FILE"
        problem_detail="other users can change $endpoint_file, mode $mode; the compositor-mcp bridge won't use it"
        return 1
    fi
    ep_url=$(field url)
    ep_pid=$(field pid)
    ep_version=$(field app_version)
    if [ -z "$ep_url" ] || ! [[ "$ep_pid" =~ ^[0-9]+$ ]] || [ "$ep_pid" -eq 0 ]; then
        problem="BROKEN ENDPOINT FILE"
        problem_detail="$endpoint_file has no usable url and pid"
        return 1
    fi
    if ! [[ "$ep_url" =~ $LOOPBACK_URL ]]; then
        problem="UNTRUSTED ENDPOINT FILE"
        problem_detail="$endpoint_file names $ep_url, which isn't this Mac's loopback address; the compositor-mcp bridge won't use it"
        return 1
    fi
    if ! kill -0 "$ep_pid" 2>/dev/null; then
        problem="STALE"
        problem_detail="the endpoint file names pid $ep_pid, which is no longer running: a crash or forced quit left it behind"
        return 1
    fi
    command=$(ps -o comm= -p "$ep_pid" 2>/dev/null)
    if [ "${command##*/}" != "Compositor" ]; then
        problem="STALE"
        problem_detail="the endpoint file names pid $ep_pid, which is now ${command##*/}, not Compositor"
        return 1
    fi
    ep_auth=$(field auth)
    ep_token_file=$(field token_file)
    # Only an absolute path, as the bridge requires.
    [[ "$ep_token_file" == /* ]] || ep_token_file=""
    return 0
}

pid=""
version=""
published=""
if [ -z "$url" ]; then
    if ! read_endpoint; then
        status "$problem ($problem_detail)"
        case $problem in
            "NOT RUNNING") start_fixes ;;
            "BROKEN ENDPOINT FILE")
                fix "quit and reopen Compositor: at launch it deletes an endpoint file it can't use, and its server writes a new one"
                fix "or delete that file yourself; the running server rewrites it the next time it is asked to start" ;;
            "UNTRUSTED ENDPOINT FILE")
                fix "Compositor writes its endpoint file for this user only (0600): delete this one, then turn the server off and on in Compositor > Settings… (or relaunch Compositor) so it writes a new one"
                fix "if it comes back like this, something else is writing there: tell the owner" ;;
            STALE)
                fix "open Compositor again: at launch it deletes the stale file, and its server writes a fresh one when it starts"
                start_fixes ;;
        esac
        exit 1
    fi
    url=$ep_url
    published=$ep_url
elif read_endpoint; then
    # --url: the running Compositor's own URL gets its token; any other gets none unless --token-file names one.
    published=$ep_url
fi
if [ -n "$published" ] && [ "$url" = "$published" ]; then
    pid=$ep_pid
    version=$ep_version
    # "auth": "bearer" means every request needs the access token, kept in the file token_file names.
    if [ -z "$token_file" ] && [ "$ep_auth" = bearer ]; then
        token_file=$ep_token_file
        if [ -z "$token_file" ]; then
            status "BROKEN ENDPOINT FILE ($endpoint_file asks for an access token but names no token_file, an absolute path)"
            fix "restart Compositor's MCP server (turn it off and on in Compositor > Settings…): it writes the file again"
            exit 1
        fi
    fi
fi

# The token, checked as the bridge checks it: this user's own file, readable by no one else, holding a token.
token=""
if [ -n "$token_file" ]; then
    token_fix() {
        fix "restart Compositor's MCP server (turn it off and on in Compositor > Settings…): it makes the token file again, owner-only"
    }
    if [ ! -f "$token_file" ] || [ ! -r "$token_file" ]; then
        status "TOKEN UNUSABLE (the access token file $token_file is missing or can't be read)"
        token_fix
        exit 1
    fi
    if [ "$(stat -f '%u' "$token_file")" != "$(id -u)" ]; then
        status "TOKEN UNUSABLE (the access token file $token_file belongs to another user; the compositor-mcp bridge won't use it)"
        token_fix
        exit 1
    fi
    mode=$(stat -f '%Lp' "$token_file")
    if [ $(( 8#$mode & 8#077 )) -ne 0 ]; then
        status "TOKEN UNUSABLE (the access token file $token_file is open to other users, mode $mode; the compositor-mcp bridge won't use it)"
        fix "chmod 600 \"$token_file\", then run this again"
        token_fix
        exit 1
    fi
    token=$(tr -d ' \t\r\n' < "$token_file")
    if ! [[ "$token" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
        status "TOKEN UNUSABLE (the access token file $token_file doesn't hold a token)"
        fix "regenerate the token in Compositor > Settings… (Regenerate token…)"
        exit 1
    fi
fi

port=${url#*://}
port=${port%%/*}
port=${port##*:}
port_note() {
    # A URL the running Compositor didn't publish isn't its server: the fixes name the one it did.
    [ -n "$published" ] && [ "$url" != "$published" ] && return
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ne $DEFAULT_PORT ]; then
        note "the server is on port $port, not the default $DEFAULT_PORT: 2667 was taken (by another app or a second Compositor) or Compositor > Settings… sets another port. Clients set up for :$DEFAULT_PORT don't reach this one; copy fresh setup lines from Compositor > Settings…, or free $DEFAULT_PORT and restart the server."
    fi
}

body_file=$(mktemp "${TMPDIR:-/tmp}/check-compositor.XXXXXX") || exit 1
trap 'rm -f "$body_file"' EXIT

# -q ignores ~/.curlrc and --noproxy keeps loopback traffic away from any proxy: the request
# must reach Compositor with Host 127.0.0.1:<port> and no Origin header, or it is refused. The
# Authorization header comes in on stdin (-H @-), so the token is never on a command line that
# other users could see with ps.
auth_header=""
[ -n "$token" ] && auth_header="Authorization: Bearer $token"
http_status=$(printf '%s\n' "$auth_header" | curl -q -sS --noproxy '*' --max-time "$TIMEOUT_SECONDS" \
    -o "$body_file" -w '%{http_code}' -H @- \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    --data "$PING" "$url" 2>/dev/null)
curl_status=$?

case $curl_status in
    0) ;;
    7)
        status "NOT LISTENING (nothing accepts connections at $url)"
        if [ -n "$pid" ]; then
            fix "Compositor (pid $pid) published this URL but isn't listening there now: open Compositor > Settings… to see the server's state and port, and turn the switch off and on again"
        elif [ -n "$published" ]; then
            fix "Compositor serves $published: set clients up with that URL (copy their setup from Compositor > Settings…), or better, through the compositor-mcp bridge, which finds it by itself"
        else
            fix "check the port: Compositor > Settings… shows the live one, and so does the endpoint file (run this script without --url)"
        fi
        start_fixes
        exit 1 ;;
    28)
        status "NO ANSWER (no reply from $url within $TIMEOUT_SECONDS s)"
        fix "Compositor may be busy or waiting on a dialog or a macOS privacy prompt: bring it to the front, answer what it shows, then run this again"
        exit 1 ;;
    *)
        status "UNEXPECTED (the ping to $url failed: curl exit $curl_status, HTTP ${http_status:-none})"
        fix "make sure the URL is Compositor's endpoint, http://127.0.0.1:<port>/mcp, and run this again"
        exit 1 ;;
esac

case $http_status in
    200)
        # A JSON-RPC answer with a top-level result, as the bridge's own probe requires; the word
        # "result" somewhere else in the body (an error message, say) is not one.
        if plutil -extract result json -o /dev/null "$body_file" 2>/dev/null; then
            details=""
            [ -n "$version" ] && details="Compositor $version"
            [ -n "$pid" ] && details="${details:+$details, }pid $pid"
            status "OK $url${details:+ ($details)}"
            port_note
            exit 0
        fi
        status "UNEXPECTED (HTTP 200 from $url, but no JSON-RPC result: $(head -c 200 "$body_file" | tr '\n' ' '))"
        fix "something other than Compositor may be answering on this port: quit it, or move Compositor to another port in Compositor > Settings…" ;;
    401)
        if [ -n "$token" ]; then
            status "REFUSED 401 (Compositor refused the access token in $token_file: the token changed, or another Compositor answers at $url)"
        elif [ -n "$pid" ]; then
            status "REFUSED 401 (Compositor requires its access token, and this check sent none: the endpoint file doesn't ask for one)"
            fix "turn the server off and on in Compositor > Settings…, so it writes its endpoint file again, then run this again"
        else
            # Never offer to send the token here: whatever answers at an unpublished URL may not be Compositor.
            status "REFUSED 401 (the server at $url requires an access token, and this check sent none: it sends Compositor's token only to the URL the running Compositor published${published:+, $published})"
            if [ -n "$published" ]; then
                fix "Compositor serves $published, not $url: run this without --url to check it, and set clients up with that URL"
            else
                fix "run this without --url to check the running Compositor's own endpoint; while Compositor isn't serving, whatever answers at $url isn't it"
            fi
        fi
        fix "connect clients through the compositor-mcp bridge, which finds the running Compositor and sends the token only to it"
        fix "a client that connects over HTTP must send Authorization: Bearer <token> with the current token: copy its setup again from Compositor > Settings… (Claude Code: claude mcp remove compositor, then add it again)" ;;
    403)
        status "REFUSED 403 (the request carried an Origin header, which Compositor refuses so that no web page can drive it)"
        fix "connect from an MCP client such as Claude Code, Codex or the compositor-mcp bridge, never a browser; remove any proxy or tool that adds an Origin header" ;;
    421)
        status "REFUSED 421 (the Host header didn't name loopback with the server's port)"
        fix "use exactly http://127.0.0.1:$port/mcp: not the Mac's name or network address, and not through a proxy" ;;
    405)
        status "REFUSED 405 (Compositor answers POST only; GET and DELETE get 405)"
        fix "set the client up for Streamable HTTP, which POSTs every message: claude mcp add --transport http ..., or codex mcp add ... --url ...; not SSE" ;;
    400|406|415)
        status "REFUSED $http_status (Compositor rejected the request's headers or body)"
        fix "an MCP client must POST JSON-RPC with Content-Type: application/json and an Accept header that allows application/json (MCP clients send application/json, text/event-stream); update the client" ;;
    503)
        status "STARTING (HTTP 503: the server is listening but not ready yet)"
        fix "wait a second and run this again; the server is still starting" ;;
    *)
        status "UNEXPECTED (HTTP $http_status from $url)"
        fix "check that the URL ends in /mcp and names Compositor's port (Compositor > Settings… shows it)" ;;
esac
port_note
exit 1
