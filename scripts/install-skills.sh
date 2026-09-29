#!/bin/bash
# Installs Compositor's agent skills for Claude Code and Codex by linking, never copying:
#
#   ~/.agents/skills/<name>  ->  <this repo>/skills/<name>
#   ~/.claude/skills/<name>  ->  ~/.agents/skills/<name>
#   ~/.codex/skills/<name>   ->  ~/.agents/skills/<name>
#
# so the installed skills always match this checkout. Running it again changes nothing.
# It only ever creates or removes those symbolic links (and the three skills folders when
# missing): a real file or folder in the way, or a link that points somewhere else, is
# reported and left alone. --uninstall removes only links that point where this script
# would have pointed them, and leaves a skill's client links alone when its ~/.agents link
# belongs to another checkout (a sibling worktree's install stays connected).
#
# Run it from the main checkout, the one you keep: the links point into whichever checkout runs
# it, so an install from a temporary worktree dangles once that worktree is removed (and an
# install or uninstall from the main checkout then refuses or leaves those links).
#
# Usage: scripts/install-skills.sh [--dry-run] [--uninstall]
#   --dry-run    print what would change, change nothing
#   --uninstall  remove this checkout's links instead of creating them
# The folders are found under $HOME; set HOME to install somewhere else (as the tests do).

set -u

usage() {
    echo "usage: $(basename "$0") [--dry-run] [--uninstall]" >&2
    echo "Run it from the main checkout: the links point into the checkout that runs it." >&2
}

dry_run=0
uninstall=0
for argument in "$@"; do
    case "$argument" in
        --dry-run) dry_run=1 ;;
        --uninstall) uninstall=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install-skills: unknown argument $argument" >&2; usage; exit 2 ;;
    esac
done

if [ -z "${HOME:-}" ]; then
    echo "install-skills: HOME is not set" >&2
    exit 2
fi

repo=$(cd "$(dirname "$0")/.." && pwd -P)
skills="$repo/skills"
agents="$HOME/.agents/skills"
clients=("$HOME/.claude/skills" "$HOME/.codex/skills")

names=()
for skill_md in "$skills"/*/SKILL.md; do
    [ -f "$skill_md" ] || continue
    names+=("$(basename "$(dirname "$skill_md")")")
done
if [ ${#names[@]} -eq 0 ]; then
    echo "install-skills: no skills found in $skills" >&2
    exit 2
fi

refused=0

# Runs a command, or only says what it would do in a dry run. $1 is the past-tense verb.
act() {
    local done_verb=$1 message=$2
    shift 2
    if [ $dry_run -eq 1 ]; then
        echo "would $message"
    elif "$@"; then
        echo "$done_verb ${message#* }"
    else
        echo "failed to $message" >&2
        refused=1
        return 1
    fi
}

ensure_dir() {
    [ -d "$1" ] && return 0
    if [ -e "$1" ] || [ -L "$1" ]; then
        echo "refuse $1: exists and is not a folder"
        refused=1
        return 1
    fi
    act "created" "create $1" mkdir -p "$1"
}

# The physical path of $2, a relative path taken from folder $1, without resolving $2's last component.
physical() {
    local base=$1 path=$2 folder
    case "$path" in
        /*) ;;
        *) path="$base/$path" ;;
    esac
    folder=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
    echo "$folder/$(basename "$path")"
}

# Whether the link at $1 points at $2, however the link spells it (absolute, or relative such as
# ../../.agents/skills/<name>).
points_at() {
    local link=$1 target=$2 current here there
    current=$(readlink "$link") || return 1
    [ "$current" = "$target" ] && return 0
    here=$(physical "$(dirname "$link")" "$current") || return 1
    there=$(physical / "$target") || return 1
    [ "$here" = "$there" ]
}

# Creates the link $1 -> $2 unless it is already there. Returns 1 when something else is in the way.
link() {
    local path=$1 target=$2
    if [ -L "$path" ]; then
        if points_at "$path" "$target"; then
            echo "ok $path (already linked)"
            return 0
        fi
        echo "refuse $path: a link to $(readlink "$path") is already there; remove it to install"
        refused=1
        return 1
    fi
    if [ -e "$path" ]; then
        echo "refuse $path: a file or folder this script did not create is there"
        refused=1
        return 1
    fi
    act "linked" "link $path -> $target" ln -s "$target" "$path"
}

# Removes the link $1 only when it points at $2.
unlink_if_ours() {
    local path=$1 target=$2
    if [ -L "$path" ] && points_at "$path" "$target"; then
        act "removed" "remove $path" rm "$path"
    elif [ -e "$path" ] || [ -L "$path" ]; then
        echo "leave $path: not a link this script made"
    fi
}

if [ $uninstall -eq 1 ]; then
    for name in "${names[@]}"; do
        # A client link to ~/.agents/skills/<name> is this checkout's only while that entry is this
        # checkout's link (or gone, leaving the client link dangling). When the entry belongs to
        # another checkout, such as a sibling worktree or the main checkout, its client links are
        # part of that install: removing them would disconnect it from Claude Code and Codex.
        entry="$agents/$name"
        if { [ -e "$entry" ] || [ -L "$entry" ]; } && ! points_at "$entry" "$skills/$name"; then
            for client in "${clients[@]}"; do
                if [ -e "$client/$name" ] || [ -L "$client/$name" ]; then
                    echo "leave $client/$name: $entry is not this checkout's link, so this is not either"
                fi
            done
            echo "leave $entry: not this checkout's link"
            continue
        fi
        for client in "${clients[@]}"; do
            unlink_if_ours "$client/$name" "$entry"
        done
        unlink_if_ours "$entry" "$skills/$name"
    done
else
    folders_ready=1
    for folder in "$agents" "${clients[@]}"; do
        ensure_dir "$folder" || folders_ready=0
    done
    if [ $folders_ready -eq 1 ]; then
        for name in "${names[@]}"; do
            # Clients link through ~/.agents/skills, so they are linked only when that link is this checkout's.
            link "$agents/$name" "$skills/$name" || continue
            for client in "${clients[@]}"; do
                link "$client/$name" "$agents/$name"
            done
        done
    fi
fi

if [ $dry_run -eq 1 ]; then
    echo "dry run: nothing was changed"
fi
exit $refused
