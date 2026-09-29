#!/bin/bash
# Starts, checks and stops the dedicated Compositor instance the skill evals run against.
#
# Usage: instance.sh start [--no-build] [--derived-data <path>] | status | stop
#
# start   builds Compositor from this checkout (Debug, CODE_SIGNING_ALLOWED=NO) unless --no-build, claims a port
#         with portclaim (service compositor-mcp-eval, never 2667), and launches the app binary directly (not via
#         open, so LaunchServices can't pick /Applications and the arguments apply) with --mcp -mcp.port <port>.
#         The app runs with CFFIXED_USER_HOME=<sandbox>/home, so its Application Support (the Agent folder, the
#         endpoint file, imported profiles) and ~ are there, outside the owner's files and outside any checkout.
#         UserDefaults still reads the owner's com.wonderassembly.compositor domain, so launch arguments (the
#         volatile argument domain) keep it read-only in practice: -mcp.port, the migration markers (so the
#         one-time sandbox migration neither runs nor records itself) and Sparkle's automatic checks off. The
#         domain is exported before and compared after; a mcp.port key that appeared is removed.
#         Ready when the endpoint file names this pid and the claimed port, and check-compositor.sh gets a ping. When
#         the instance requires its access token (the default), it keeps the token in its own home; the check is
#         given that token file (and runs with HOME there), and state.json names it for run_eval (never the token).
# status  prints the recorded instance and pings it; exit 0 when it answers.
# stop    kill -TERM (it quits without a dialog and leaves its endpoint file, which is then removed: the one
#         state.json recorded, whatever SKILLS_EVAL_SANDBOX says now), releases the port, compares the defaults
#         domain and forgets the instance.
#
# Environment: SKILLS_EVAL_WORKSPACE (default <checkout>/skills-workspace; state in instance/), SKILLS_EVAL_SANDBOX
# (default $TMPDIR/compositor-skills-eval), SKILLS_EVAL_DD (DerivedData, default <workspace>/DerivedData),
# PORTCLAIM (default portclaim), COMPOSITOR_DEFAULTS_DOMAIN (default com.wonderassembly.compositor).

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
workspace=${SKILLS_EVAL_WORKSPACE:-$repo/skills-workspace}
tmp_root=${TMPDIR:-/tmp}
sandbox=${SKILLS_EVAL_SANDBOX:-${tmp_root%/}/compositor-skills-eval}
derived_data=${SKILLS_EVAL_DD:-$workspace/DerivedData}
portclaim=${PORTCLAIM:-portclaim}
domain=${COMPOSITOR_DEFAULTS_DOMAIN:-com.wonderassembly.compositor}
state_dir=$workspace/instance
state=$state_dir/state.json
home=$sandbox/home
support="$home/Library/Application Support/Compositor"
endpoint_file="$support/mcp/endpoint.json"
check=$repo/skills/compositor-setup/scripts/check-compositor.sh

usage() {
    echo "usage: instance.sh start [--no-build] [--derived-data <path>] | status | stop" >&2
}

fail() {
    echo "instance.sh: $*" >&2
    exit 1
}

# A top-level value of a JSON file, or nothing.
json_field() {
    plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

alive() {
    [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

# Whether the pid is still the app binary this script launched (not a reused pid).
is_our_app() {
    alive "$1" && ps -o command= -p "$1" 2>/dev/null | grep -qF "$2"
}

port_default() {
    defaults read "$domain" mcp.port 2>/dev/null || echo absent
}

# Removes an endpoint file (default: this sandbox's) whose pid is dead.
remove_dead_endpoint() {
    local file=${1:-$endpoint_file}
    [ -f "$file" ] || return 0
    local pid
    pid=$(json_field "$file" pid)
    if ! alive "$pid"; then
        rm -f "$file"
        echo "removed the endpoint file naming dead pid ${pid:-?}"
    fi
}

# Prints keys whose values differ between two exported defaults plists.
defaults_changes() {
    python3 - "$1" "$2" <<'EOF'
import plistlib, sys
def load(path):
    try:
        with open(path, "rb") as handle:
            return plistlib.load(handle)
    except Exception:
        return {}
before, after = load(sys.argv[1]), load(sys.argv[2])
for key in sorted(set(before) | set(after)):
    if before.get(key) != after.get(key):
        print(key)
EOF
}

write_state() {
    python3 - "$state" "$@" <<'EOF'
import json, sys
path, pid, port, app, home, sandbox, endpoint, before, derived, token_file = sys.argv[1:]
agent = home + "/Library/Application Support/Compositor/Agent"
state = {"pid": int(pid), "port": int(port), "url": f"http://127.0.0.1:{port}/mcp", "app": app, "home": home,
         "sandbox": sandbox, "agent_folder": agent, "endpoint_file": endpoint, "mcp_port_default_before": before,
         "derived_data": derived, "token_file": token_file or None}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle, indent=2)
    handle.write("\n")
EOF
}

stop_app() {
    local pid=$1 app=$2
    if is_our_app "$pid" "$app"; then
        kill -TERM "$pid"
        for _ in $(seq 1 40); do
            alive "$pid" || break
            sleep 0.5
        done
        if alive "$pid"; then
            echo "warning: pid $pid ignored TERM for 20 s; sending KILL" >&2
            kill -KILL "$pid"
        fi
        echo "stopped Compositor (pid $pid)"
    elif alive "$pid"; then
        echo "warning: pid $pid is no longer the eval app; left it alone" >&2
    fi
}

compare_defaults() {
    local before=$1
    local after
    after=$(port_default)
    echo "defaults $domain mcp.port: before $before, after $after"
    if [ "$before" = absent ] && [ "$after" != absent ]; then
        defaults delete "$domain" mcp.port && echo "removed the mcp.port key the eval instance left in $domain"
    fi
    if [ -f "$state_dir/defaults-before.plist" ]; then
        defaults export "$domain" "$state_dir/defaults-after.plist" 2>/dev/null
        local changed
        changed=$(defaults_changes "$state_dir/defaults-before.plist" "$state_dir/defaults-after.plist")
        if [ -n "$changed" ]; then
            echo "warning: keys in $domain changed while the instance ran: $(echo "$changed" | tr '\n' ' ')" >&2
        else
            echo "defaults $domain: unchanged"
        fi
    fi
}

start() {
    local build=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-build) build=0; shift ;;
            --derived-data)
                [ $# -ge 2 ] || { usage; exit 2; }
                derived_data=$2; shift 2 ;;
            *) usage; exit 2 ;;
        esac
    done
    if [ -f "$state" ]; then
        local pid app
        pid=$(json_field "$state" pid)
        app=$(json_field "$state" app)
        if is_our_app "$pid" "$app"; then
            echo "already running: pid $pid, $(json_field "$state" url)"
            return 0
        fi
        echo "the recorded instance (pid ${pid:-?}) is gone; cleaning up first"
        stop
    fi
    mkdir -p "$state_dir" "$home"
    if [ $build -eq 1 ]; then
        echo "building into $derived_data (log: $state_dir/build.log)"
        xcodebuild build -project "$repo/Compositor.xcodeproj" -scheme Compositor -destination 'platform=macOS' \
            -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO >"$state_dir/build.log" 2>&1 \
            || fail "build failed; see $state_dir/build.log"
    fi
    local app="$derived_data/Build/Products/Debug/Compositor.app/Contents/MacOS/Compositor"
    [ -x "$app" ] || fail "no app at $app (build first, or pass --derived-data)"

    local before
    before=$(port_default)
    defaults export "$domain" "$state_dir/defaults-before.plist" 2>/dev/null
    local port
    port=$("$portclaim" acquire --service compositor-mcp-eval --project Compositor --lease persistent --json \
        | plutil -extract port raw -o - - 2>/dev/null)
    [[ "$port" =~ ^[0-9]+$ ]] || fail "portclaim did not hand out a port"
    if [ "$port" -eq 2667 ]; then
        "$portclaim" release "$port" >/dev/null
        fail "portclaim handed out 2667, Compositor's default port; refusing"
    fi
    remove_dead_endpoint >/dev/null

    # From the sandbox: a Debug build instrumented for coverage (as `xcodebuild test` leaves it) writes
    # default.profraw into its working folder, which must not be the checkout. exec keeps the pid the app's.
    (cd "$sandbox" && CFFIXED_USER_HOME="$home" exec nohup "$app" --mcp -mcp.port "$port" \
        -ApplePersistenceIgnoreState YES \
        -migration.sandboxPreferences.v1 YES -migration.sandboxAgentFolder.v1 YES \
        -SUEnableAutomaticChecks NO -SUAutomaticallyUpdate NO) \
        >"$state_dir/app.log" 2>&1 </dev/null &
    local pid=$!
    write_state "$pid" "$port" "$app" "$home" "$sandbox" "$endpoint_file" "$before" "$derived_data" ""

    local ready=0
    for _ in $(seq 1 120); do
        if ! alive "$pid"; then
            break
        fi
        if [ -f "$endpoint_file" ] && [ "$(json_field "$endpoint_file" pid)" = "$pid" ]; then
            ready=1
            break
        fi
        sleep 0.5
    done
    local published
    published=$(json_field "$endpoint_file" port)
    if [ $ready -eq 0 ] || [ "$published" != "$port" ]; then
        echo "instance.sh: Compositor did not come up on port $port" \
            "(endpoint port ${published:-none}; log: $state_dir/app.log)" >&2
        stop >/dev/null
        exit 1
    fi
    # The instance's access token, if it requires one, is in its home, named by its endpoint file. The check sends
    # a token to a --url only when told which, and this is the instance's own port, so it is told.
    local token_file=""
    [ "$(json_field "$endpoint_file" auth)" = bearer ] && token_file=$(json_field "$endpoint_file" token_file)
    if ! HOME="$home" bash "$check" --url "http://127.0.0.1:$port/mcp" ${token_file:+--token-file "$token_file"}; then
        stop >/dev/null
        fail "Compositor (pid $pid) did not answer a ping on port $port"
    fi
    write_state "$pid" "$port" "$app" "$home" "$sandbox" "$endpoint_file" "$before" "$derived_data" "$token_file"
    echo "defaults $domain mcp.port: before $before, now $(port_default)"
    echo "Compositor eval instance: pid $pid, http://127.0.0.1:$port/mcp"
    echo "Agent folder: $support/Agent"
}

status() {
    if [ ! -f "$state" ]; then
        echo "not running (no $state)"
        return 1
    fi
    local pid url app token_file
    pid=$(json_field "$state" pid)
    url=$(json_field "$state" url)
    app=$(json_field "$state" app)
    token_file=$(json_field "$state" token_file)
    echo "recorded: pid $pid, $url, home $(json_field "$state" home)"
    if ! is_our_app "$pid" "$app"; then
        echo "not running (pid $pid is gone)"
        return 1
    fi
    HOME="$(json_field "$state" home)" bash "$check" --url "$url" ${token_file:+--token-file "$token_file"}
}

stop() {
    if [ ! -f "$state" ]; then
        echo "not running (no $state)"
        return 0
    fi
    local pid port app before recorded_endpoint
    pid=$(json_field "$state" pid)
    port=$(json_field "$state" port)
    app=$(json_field "$state" app)
    before=$(json_field "$state" mcp_port_default_before)
    # The file this instance wrote, wherever SKILLS_EVAL_SANDBOX points now.
    recorded_endpoint=$(json_field "$state" endpoint_file)
    stop_app "$pid" "$app"
    remove_dead_endpoint "${recorded_endpoint:-$endpoint_file}"
    if [ -n "$port" ]; then
        "$portclaim" release "$port"
    fi
    compare_defaults "${before:-absent}"
    rm -f "$state"
}

command=${1:-}
[ $# -gt 0 ] && shift
case "$command" in
    start) start "$@" ;;
    status) status ;;
    stop) stop ;;
    *) usage; exit 2 ;;
esac
