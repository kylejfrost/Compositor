#!/bin/bash
# Gathers what's needed to look into a problem with Compositor, its MCP server or the compositor-mcp bridge into
# one timestamped folder, on this Mac or on another one over SSH:
#
#   compositor/        Compositor's diagnostic log (compositor-*.jsonl) and the bridge's (bridge*.jsonl), only the
#                      lines since the time given
#   unified-log.ndjson the unified log for subsystem com.wonderassembly.compositor since then
#   crash-reports/     Compositor's and the bridge's crash reports since then
#   defaults.txt       Compositor's preferences, less any key containing "token"
#   app.txt            the installed Compositor's version and build, and the running copies
#   system.txt         macOS version, machine model and architecture
#   hermes/            when present: Hermes's logs (~/.hermes/logs/*.log) since then, with every line mentioning a
#                      key, token, secret or password replaced, and `hermes mcp list`, redacted the same way
#
# It reads only those places: never Documents, Desktop or any other folder of files. The last line it prints is the
# bundle's path. docs/logging.md describes the logs themselves.
#
# Usage: scripts/collect-logs.sh [--host <ssh-alias>] [--since <duration|time>] [--out <folder>]
#   --host <ssh-alias>  collect on that Mac over SSH (it needs nothing installed) and copy the bundle back here
#   --since <when>      a duration (30m, 6h, 2d; default 24h) or a time (2026-09-24T14:00:00Z in UTC, or
#                       "2026-09-24 10:00" in local time)
#   --out <folder>      where the bundle goes (default ~/Library/Logs/Compositor/collected)
# COMPOSITOR_APP names the app to report on when it isn't /Applications/Compositor.app or ~/Applications.

set -euo pipefail

usage() {
    echo "usage: $(basename "$0") [--host <ssh-alias>] [--since <duration|time>] [--out <folder>]" >&2
    echo "  --since takes 30m, 6h, 2d (default 24h), 2026-09-24T14:00:00Z (UTC) or \"2026-09-24 10:00\" (local)." >&2
}

host=""
since="24h"
out=""
# Internal, used by --host on the far side: write the bundle as a tar stream to stdout, named this.
as_tar=false
name=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host|--since|--out|--name)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then echo "$1 needs a value" >&2; usage; exit 64; fi
            case "$1" in
                --host) host="$2" ;;
                --since) since="$2" ;;
                --out) out="$2" ;;
                --name) name="$2" ;;
            esac
            shift 2 ;;
        --tar) as_tar=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument $1" >&2; usage; exit 64 ;;
    esac
done

# Seconds since 1970 for --since's value; nothing (and a usage error) for anything else.
since_epoch() {
    local value="$1" now amount unit
    now=$(date +%s)
    case "$value" in
        *[0-9]s|*[0-9]m|*[0-9]h|*[0-9]d)
            amount="${value%?}"
            unit="${value#"$amount"}"
            case "$amount" in ''|*[!0-9]*) return 1 ;; esac
            case "$unit" in
                s) echo $((now - amount)) ;;
                m) echo $((now - amount * 60)) ;;
                h) echo $((now - amount * 3600)) ;;
                d) echo $((now - amount * 86400)) ;;
            esac
            return 0 ;;
    esac
    # Fractions of a second are dropped; Z means UTC, anything else is local time.
    local trimmed="${value%%.*}"
    case "$value" in *Z) trimmed="${trimmed%Z}Z" ;; esac
    local format
    for format in "%Y-%m-%dT%H:%M:%SZ" "%Y-%m-%dT%H:%M:%S" "%Y-%m-%d %H:%M:%S" "%Y-%m-%d %H:%M" "%Y-%m-%d"; do
        if [ "${format%Z}" != "$format" ]; then
            date -j -u -f "$format" "$trimmed" +%s 2>/dev/null && return 0
        else
            date -j -f "$format" "$trimmed" +%s 2>/dev/null && return 0
        fi
    done
    return 1
}

if ! epoch=$(since_epoch "$since"); then
    echo "--since must be a duration like 6h or a time like 2026-09-24T14:00:00Z, not \"$since\"" >&2
    usage
    exit 64
fi

stamp=$(date +%Y%m%d-%H%M%S)

# --host: the same script runs over there and streams its bundle back; nothing is left on the other Mac.
if [ -n "$host" ]; then
    destination="${out:-$HOME/Library/Logs/Compositor/collected}"
    mkdir -p "$destination"
    bundle_name="compositor-logs-$host-$stamp"
    echo "collecting on $host..." >&2
    ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" \
        "bash -s -- --since $(printf %q "$since") --name $(printf %q "$bundle_name") --tar" < "$0" \
        | tar -xzf - -C "$destination"
    if [ ! -d "$destination/$bundle_name" ]; then
        echo "nothing came back from $host" >&2
        exit 1
    fi
    echo "$destination/$bundle_name"
    exit 0
fi

# Commands that could hang (the unified log over a long span, Hermes) get this long.
run_limited() {
    local seconds="$1"
    shift
    "$@" &
    local pid=$!
    ( sleep "$seconds"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    local watchdog=$!
    # Not a job bash reports on ("Terminated") when it's stopped below.
    disown "$watchdog" 2>/dev/null || true
    local status=0
    wait "$pid" || status=$?
    # Only while it still runs: once it has fired and gone, its pid may belong to something else.
    if kill -0 "$watchdog" 2>/dev/null; then
        pkill -P "$watchdog" 2>/dev/null || true
        kill "$watchdog" 2>/dev/null || true
    fi
    return "$status"
}

# Hermes, when it's installed somewhere a login shell would find it (ssh runs a plain one).
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"

since_utc=$(date -u -r "$epoch" "+%Y-%m-%dT%H:%M:%S.000Z")
since_local=$(date -r "$epoch" "+%Y-%m-%d %H:%M:%S")
host_name=$(hostname -s 2>/dev/null || echo mac)

if $as_tar; then
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    bundle="$work/${name:-compositor-logs-$host_name-$stamp}"
else
    destination="${out:-$HOME/Library/Logs/Compositor/collected}"
    bundle="$destination/${name:-compositor-logs-$host_name-$stamp}"
fi
mkdir -p "$bundle"
chmod 700 "$bundle"
notes=()

# Lines of the app's and the bridge's JSON Lines logs from `since` on: each line starts {"ts":"<UTC time>", so the
# comparison is plain text. Files with nothing since are left out.
logs="$HOME/Library/Logs/Compositor"
if [ -d "$logs" ]; then
    mkdir -p "$bundle/compositor"
    for file in "$logs"/compositor-*.jsonl "$logs"/bridge*.jsonl; do
        [ -f "$file" ] || continue
        target="$bundle/compositor/$(basename "$file")"
        awk -v since="$since_utc" 'substr($0, 1, 7) == "{\"ts\":\"" && substr($0, 8, 24) >= since' "$file" > "$target" || true
        [ -s "$target" ] || rm -f "$target"
    done
    rmdir "$bundle/compositor" 2>/dev/null || true
else
    notes+=("No Compositor log folder at $logs.")
fi

# The unified log: --last for a duration, as `log show` takes it; --start for a time.
case "$since" in
    *[0-9]m|*[0-9]h|*[0-9]d) window=(--last "$since") ;;
    *) window=(--start "$since_local") ;;
esac
if ! run_limited 120 log show --predicate 'subsystem == "com.wonderassembly.compositor"' --style ndjson "${window[@]}" \
        > "$bundle/unified-log.ndjson" 2> "$bundle/unified-log.errors.txt"; then
    notes+=("log show failed or took over two minutes; see unified-log.errors.txt.")
fi
[ -s "$bundle/unified-log.errors.txt" ] || rm -f "$bundle/unified-log.errors.txt"

reports="$HOME/Library/Logs/DiagnosticReports"
if [ -d "$reports" ]; then
    mkdir -p "$bundle/crash-reports"
    find "$reports" -maxdepth 1 -type f \( -name 'Compositor*' -o -name 'compositor-mcp*' \) -newermt "$since_local" \
        -exec cp -p {} "$bundle/crash-reports/" \; 2>/dev/null || true
    rmdir "$bundle/crash-reports" 2>/dev/null || true
fi

# Nothing secret is kept there, but a key that so much as mentions a token is left out all the same.
defaults read com.wonderassembly.compositor 2>&1 | grep -iv token > "$bundle/defaults.txt" || true

{
    app="${COMPOSITOR_APP:-}"
    if [ -z "$app" ]; then
        for candidate in /Applications/Compositor.app "$HOME/Applications/Compositor.app"; do
            if [ -d "$candidate" ]; then app="$candidate"; break; fi
        done
    fi
    if [ -n "$app" ] && [ -f "$app/Contents/Info.plist" ]; then
        echo "app: $app"
        echo "version: $(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist" 2>/dev/null || echo "?")"
        echo "build: $(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist" 2>/dev/null || echo "?")"
    else
        echo "app: not found in /Applications or ~/Applications"
    fi
    echo "running:"
    pgrep -lf 'Compositor.app/Contents/MacOS/' 2>/dev/null || echo "  (none)"
} > "$bundle/app.txt"

{
    sw_vers 2>/dev/null || true
    echo "model: $(sysctl -n hw.model 2>/dev/null || echo "?")"
    echo "arch: $(uname -m)"
    echo "uptime:$(uptime)"
} > "$bundle/system.txt"

# Replaces every line that mentions a key, token, secret or password (or an Authorization header or bearer
# credential).
redact() {
    awk '{ line = tolower($0); if (line ~ /key|token|secret|password|authorization|bearer/) print "[line redacted: it mentioned a key, token, secret or password]"; else print }'
}

hermes_logs="$HOME/.hermes/logs"
if [ -d "$hermes_logs" ]; then
    mkdir -p "$bundle/hermes"
    for file in "$hermes_logs"/*.log; do
        [ -f "$file" ] || continue
        target="$bundle/hermes/$(basename "$file")"
        if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}' "$file"; then
            # Lines stamped in local time from `since` on, with the unstamped lines that follow them.
            awk -v since="$since_local" '
                /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ {
                    stamp = substr($0, 1, 19); sub("T", " ", stamp); keep = (stamp >= since)
                }
                keep { print }' "$file" | redact | tail -n 20000 > "$target" || true
        else
            # No time stamps to go by: the end of the file.
            tail -n 5000 "$file" | redact > "$target" || true
        fi
        [ -s "$target" ] || rm -f "$target"
    done
    if command -v hermes >/dev/null 2>&1; then
        run_limited 30 hermes mcp list 2>&1 | redact > "$bundle/hermes/mcp-list.txt" || true
    fi
fi

{
    echo "Compositor diagnostic bundle"
    echo "host: $host_name"
    echo "collected: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "since: $since ($since_utc)"
    echo
    echo "What each file is: scripts/collect-logs.sh and docs/logging.md in the Compositor repository."
    for note in "${notes[@]+"${notes[@]}"}"; do echo "note: $note"; done
    echo
    echo "files:"
    (cd "$bundle" && find . -type f ! -name README.txt | sort | sed 's|^\./|  |')
} > "$bundle/README.txt"

if $as_tar; then
    tar -czf - -C "$work" "$(basename "$bundle")"
else
    echo "$bundle"
fi
