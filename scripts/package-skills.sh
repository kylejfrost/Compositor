#!/bin/bash
# Stages and packages Compositor's agent skills for places that get a copy of a skill instead of a link into this
# checkout: Claude Desktop, which imports a .skill file (the zip skill-creator's package_skill.py makes), and the
# skill evals, which copy a skill into each with-skill run's project.
#
#   scripts/package-skills.sh [--out <dir>] [<skill> ...]     every skill, or those named, as <dir>/<name>.skill
#                                                            (default <checkout>/dist/skills, which git ignores)
#   scripts/package-skills.sh --stage <skill folder> <dest>   the skill as it is packaged, written to <dest>
#                                                            (which must not exist yet)
#
# A staged skill leaves out evals/ (the prompts and expectations its evals are graded on) and gains copies of the
# repository scripts its references run, which a copy can't find in a checkout: psd-verify.py, psd-diff.py,
# photoshop-verify.sh and photoshop-verify.jsx go into the scripts/ of compositor-psd-templates and
# compositor-variants-and-delivery. scripts/ stays their one source of truth: a skill that carries its own file of
# the same name is refused.
#
# Packaging runs skill-creator's scripts/package_skill.py, which checks the frontmatter with PyYAML, from
# $SKILL_CREATOR (the skill-creator folder), else the first skill-creator found under ~/.claude/skills, with
# $PACKAGE_SKILLS_PYTHON (default: uv run --quiet --no-project --with pyyaml python3).

set -u

usage() {
    echo "usage: $(basename "$0") [--out <dir>] [<skill> ...]" >&2
    echo "       $(basename "$0") --stage <skill folder> <dest>" >&2
}

fail() {
    echo "package-skills: $*" >&2
    exit 1
}

repo=$(cd "$(dirname "$0")/.." && pwd -P)

# The repository scripts a skill's references run, copied into its scripts/ when it is staged.
bundled_scripts() {
    case "$1" in
        compositor-psd-templates | compositor-variants-and-delivery)
            echo psd-verify.py psd-diff.py photoshop-verify.sh photoshop-verify.jsx ;;
    esac
}

stage() {
    local source=$1 dest=$2 name script
    [ -f "$source/SKILL.md" ] || { echo "package-skills: no SKILL.md in $source" >&2; return 1; }
    [ ! -e "$dest" ] || { echo "package-skills: $dest already exists" >&2; return 1; }
    name=$(basename "$source")
    for script in $(bundled_scripts "$name"); do
        if [ -e "$source/scripts/$script" ]; then
            echo "package-skills: $source/scripts/$script would stand in for the repository's scripts/$script;" \
                "delete that copy (packaging copies the current one)" >&2
            return 1
        fi
    done
    mkdir -p "$(dirname "$dest")" || return 1
    cp -R "$source" "$dest" || return 1
    rm -rf "$dest/evals"
    find "$dest" \( -name __pycache__ -o -name .DS_Store \) -prune -exec rm -rf {} + || return 1
    for script in $(bundled_scripts "$name"); do
        mkdir -p "$dest/scripts" && cp -p "$repo/scripts/$script" "$dest/scripts/$script" || return 1
    done
}

skill_creator() {
    local creator=${SKILL_CREATOR:-} found
    if [ -z "$creator" ]; then
        found=$(find -L "$HOME/.claude/skills" -maxdepth 6 -path '*/skill-creator/scripts/package_skill.py' \
            2>/dev/null | head -n 1)
        creator=${found%/scripts/package_skill.py}
    fi
    if [ -z "$creator" ] || [ ! -f "$creator/scripts/package_skill.py" ]; then
        fail "no skill-creator with scripts/package_skill.py${creator:+ at $creator}; set SKILL_CREATOR to its folder"
    fi
    echo "$creator"
}

package() {
    local out=$1
    shift
    local names=("$@") name
    if [ ${#names[@]} -eq 0 ]; then
        for name in "$repo"/skills/*/SKILL.md; do
            names+=("$(basename "$(dirname "$name")")")
        done
    fi
    for name in "${names[@]}"; do
        if [ ! -f "$repo/skills/$name/SKILL.md" ]; then
            echo "package-skills: no skill named $name in $repo/skills" >&2
            usage
            exit 2
        fi
    done
    local creator
    creator=$(skill_creator) || exit 1
    local python
    read -r -a python <<<"${PACKAGE_SKILLS_PYTHON:-uv run --quiet --no-project --with pyyaml python3}"
    case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
    # Global, not local: the EXIT trap runs after this function has returned.
    work=$(mktemp -d "${TMPDIR:-/tmp}/package-skills.XXXXXX") || fail "can't make a staging folder"
    trap 'rm -rf "$work"' EXIT
    mkdir -p "$out" || fail "can't make $out"
    for name in "${names[@]}"; do
        stage "$repo/skills/$name" "$work/$name" || fail "could not stage $name"
        rm -f "$out/$name.skill"
        if ! (cd "$creator" && PYTHONDONTWRITEBYTECODE=1 "${python[@]}" -B -m scripts.package_skill \
            "$work/$name" "$out") >"$work/$name.log" 2>&1 || [ ! -f "$out/$name.skill" ]; then
            cat "$work/$name.log" >&2
            fail "package_skill.py could not package $name"
        fi
        echo "packaged $name: $out/$name.skill"
    done
}

case "${1:-}" in
    --stage)
        [ $# -eq 3 ] || { usage; exit 2; }
        stage "$2" "$3" || exit 1
        ;;
    -h | --help)
        usage
        ;;
    *)
        out="$repo/dist/skills"
        names=()
        while [ $# -gt 0 ]; do
            case "$1" in
                --out)
                    [ $# -ge 2 ] || { usage; exit 2; }
                    out=$2
                    shift 2 ;;
                -*) echo "package-skills: unknown argument $1" >&2; usage; exit 2 ;;
                *) names+=("$1"); shift ;;
            esac
        done
        package "$out" ${names[@]+"${names[@]}"}
        ;;
esac
