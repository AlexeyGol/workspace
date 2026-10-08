#!/usr/bin/env bash
#
# clean-up-worktrees.sh - Audit and remove git worktrees across the workspace.
#
# Worktrees end up scattered: some under worktrees/, some next to their repo in
# sources/, some in a repo's own .claude/worktrees/. This finds all of them by
# asking every repo in sources/, classifies each by whether removing it could
# lose work, and only then offers to remove.
#
# Usage:
#   ./clean-up-worktrees.sh                 # audit only, changes nothing
#   ./clean-up-worktrees.sh --interactive   # audit, then ask y/N per SAFE worktree
#   ./clean-up-worktrees.sh --yes           # remove every SAFE worktree, no prompts
#   ./clean-up-worktrees.sh 17285           # narrow to worktrees matching a filter
#   ./clean-up-worktrees.sh -i 17285        # both
#
# --interactive needs a terminal to prompt on. Claude Code's `!` shell has no
# tty, so use --yes there (always after reading a bare audit run first), or run
# --interactive in Git Bash directly.
#
# Removing a worktree deletes its working directory only. The branch is always
# kept, so anything removed here can be restored with `git worktree add`.
#
# RISK and LOCKED worktrees are never removed, and there is deliberately no
# --force: if the script says RISK, the fix is to push or inspect, not override.
#
# Needs network access to reach each repo's origin. Without it every worktree
# lands in UNKNOWN and nothing is offered for removal, which is the safe default.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="${SCRIPT_DIR}/sources"

# git reports worktree paths in Windows form (C:/...) while bash carries the
# MinGW form (/c/...), so prefix matching needs both spellings or every path
# looks foreign.
if command -v cygpath >/dev/null 2>&1; then
    SCRIPT_DIR_WIN="$(cygpath -m "$SCRIPT_DIR")"
else
    SCRIPT_DIR_WIN="$SCRIPT_DIR"
fi

# Strip whichever workspace-root spelling a path uses.
relpath() {
    local p="${1#"$SCRIPT_DIR"/}"
    echo "${p#"$SCRIPT_DIR_WIN"/}"
}

under_worktrees() {
    case "$(relpath "$1")" in worktrees/*) return 0 ;; *) return 1 ;; esac
}

INTERACTIVE=0
ASSUME_YES=0
FILTER=""

while [ $# -gt 0 ]; do
    case "$1" in
        -i|--interactive) INTERACTIVE=1 ;;
        -y|--yes)         INTERACTIVE=1; ASSUME_YES=1 ;;
        -h|--help)        awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' \
                              "${BASH_SOURCE[0]}"; exit 0 ;;
        -*)               echo "Unknown option: $1" >&2; exit 1 ;;
        *)                FILTER="$1" ;;
    esac
    shift
done

if [ ! -d "$SOURCES_DIR" ]; then
    echo "No sources/ directory yet. Run ./bootstrap.sh first."
    exit 1
fi

# Resolve a repo's own default branch. It is mixed across this workspace -
# master in edp-tekton and the older edp-* operators, main in krci-portal, cli
# and friends - so it is never assumed, always asked.
default_branch() {
    local repo="$1" def
    def="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" && def="${def#origin/}"
    if [ -z "$def" ]; then
        def="$(git -C "$repo" ls-remote --symref origin HEAD 2>/dev/null |
               awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }')"
    fi
    echo "$def"
}

# Decide whether removing this worktree could lose work. Sets STATUS and DETAIL.
#
# The subtle case: a local refs/remotes/origin/<branch> is NOT evidence the
# branch is still on the remote. It survives the branch being deleted upstream,
# so trusting it would call an orphaned commit "pushed". Hence ls-remote, and
# hence a failed probe counts as UNKNOWN rather than as absent.
classify() {
    local repo="$1" path="$2" branch="$3" locked="$4"
    STATUS=""; DETAIL=""

    if [ -n "$locked" ]; then
        STATUS="LOCKED"; DETAIL="locked${locked:+: $locked}"; return
    fi
    if [ ! -d "$path" ]; then
        STATUS="PRUNE"; DETAIL="directory is gone"; return
    fi
    if [ -z "$branch" ]; then
        STATUS="RISK"; DETAIL="detached HEAD, no branch to fall back on"; return
    fi

    local dirty
    dirty="$(git -C "$path" status --porcelain 2>/dev/null | grep -c .)"
    if [ "${dirty:-0}" -gt 0 ]; then
        STATUS="RISK"; DETAIL="$dirty uncommitted change(s)"; return
    fi

    local local_sha remote_out remote_sha
    local_sha="$(git -C "$path" rev-parse HEAD 2>/dev/null)"

    if ! remote_out="$(git -C "$repo" ls-remote --heads origin "$branch" 2>/dev/null)"; then
        STATUS="UNKNOWN"; DETAIL="cannot reach origin"; return
    fi
    remote_sha="$(echo "$remote_out" | awk 'NR==1 { print $1 }')"

    if [ -n "$remote_sha" ]; then
        if [ "$remote_sha" = "$local_sha" ]; then
            STATUS="SAFE"; DETAIL="pushed, clean"
        elif git -C "$path" merge-base --is-ancestor "$local_sha" "$remote_sha" 2>/dev/null; then
            STATUS="SAFE"; DETAIL="behind origin/$branch, nothing local to lose"
        else
            STATUS="RISK"
            DETAIL="$(git -C "$path" rev-list --count "$remote_sha..$local_sha" 2>/dev/null) commit(s) not on origin"
        fi
        return
    fi

    # No branch on the remote. Merged into the default branch is the normal
    # end of life for a ticket branch and is safe; anything else is orphaned.
    local def
    def="$(default_branch "$repo")"
    if [ -n "$def" ] && git -C "$path" merge-base --is-ancestor "$local_sha" "origin/$def" 2>/dev/null; then
        STATUS="SAFE"; DETAIL="branch gone from origin, merged into $def"
    else
        STATUS="RISK"; DETAIL="not on origin and not merged - only copy of this work"
    fi
}

REPOS=()
while IFS= read -r -d '' gitdir; do
    REPOS+=("$(dirname "$gitdir")")
done < <(find "$SOURCES_DIR" -mindepth 2 -maxdepth 5 -name .git -type d -print0 | sort -z)

PATHS=(); REPO_OF=(); BRANCHES=(); STATUSES=(); DETAILS=()

for repo in "${REPOS[@]}"; do
    main_wt=""; wt=""; branch=""; locked=""

    flush() {
        [ -z "$wt" ] && return
        # The first block git reports is the repo's own checkout, not a worktree.
        if [ -z "$main_wt" ]; then main_wt="$wt"; return; fi
        if [ -n "$FILTER" ] && [[ "$wt" != *"$FILTER"* && "$branch" != *"$FILTER"* ]]; then return; fi
        classify "$repo" "$wt" "$branch" "$locked"
        PATHS+=("$wt"); REPO_OF+=("$repo"); BRANCHES+=("$branch")
        STATUSES+=("$STATUS"); DETAILS+=("$DETAIL")
    }

    while IFS= read -r line; do
        case "$line" in
            worktree\ *) flush; wt="${line#worktree }"; branch=""; locked="" ;;
            branch\ *)   branch="${line#branch refs/heads/}" ;;
            locked*)     locked="${line#locked}"; locked="${locked# }" ;;
        esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
    flush
done

if [ "${#PATHS[@]}" -eq 0 ]; then
    echo "No worktrees found${FILTER:+ matching '$FILTER'}."
    exit 0
fi

icon() {
    case "$1" in
        SAFE) echo "✅" ;; RISK) echo "🛑" ;;
        LOCKED) echo "🔒" ;; PRUNE) echo "🧹" ;; *) echo "❓" ;;
    esac
}

echo
for i in "${!PATHS[@]}"; do
    rel="$(relpath "${PATHS[$i]}")"
    misplaced=""
    under_worktrees "${PATHS[$i]}" || misplaced="  ⚠ not under worktrees/"
    printf "%s %-7s %s\n" "$(icon "${STATUSES[$i]}")" "${STATUSES[$i]}" "$rel$misplaced"
    printf "            branch %-46s %s\n" "${BRANCHES[$i]:-<detached>}" "${DETAILS[$i]}"
done
echo

count() { local n=0 s; for s in "${STATUSES[@]}"; do [ "$s" = "$1" ] && n=$((n + 1)); done; echo "$n"; }
echo "$(count SAFE) safe, $(count RISK) at risk, $(count LOCKED) locked, $(count PRUNE) prunable, $(count UNKNOWN) unknown"

if [ "$INTERACTIVE" -eq 0 ]; then
    [ "$(count SAFE)" -gt 0 ] && echo "Re-run with --interactive to remove the safe ones."
    exit 0
fi

# Returns 0 for yes, 1 for no, 2 for "there was no way to ask". Distinguishing
# the last case matters: a declined prompt and an unanswerable one both leave
# the worktree in place, but only one of them is the user's decision.
ask() {
    local reply=""
    printf "\n%s [y/N] " "$1"
    # 2>/dev/null must come first: bash applies redirections left to right and
    # would otherwise report the failed </dev/tty before it is silenced.
    if ! read -r reply 2>/dev/null </dev/tty; then
        read -r reply || return 2
    fi
    case "$reply" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}

removed=0
for i in "${!PATHS[@]}"; do
    [ "${STATUSES[$i]}" = "SAFE" ] || continue

    if [ "$ASSUME_YES" -eq 1 ]; then
        decision=0
        printf "\nRemoving %s\n" "$(relpath "${PATHS[$i]}")"
    else
        ask "Remove $(relpath "${PATHS[$i]}") ?"
        decision=$?
    fi

    if [ "$decision" -eq 2 ]; then
        echo
        echo "⚠ No terminal available to prompt on, so nothing was removed."
        echo "  Run --interactive in Git Bash directly, or re-run with --yes to"
        echo "  remove every SAFE worktree listed above without prompting."
        break
    fi

    case "$decision" in
        0)
            if git -C "${REPO_OF[$i]}" worktree remove "${PATHS[$i]}"; then
                echo "✅ removed (branch ${BRANCHES[$i]} kept)"
                removed=$((removed + 1))
            else
                echo "❌ git declined to remove it - left in place"
            fi
            ;;
        *) echo "skipped" ;;
    esac
done

if [ "$(count PRUNE)" -gt 0 ]; then
    for repo in "${REPOS[@]}"; do git -C "$repo" worktree prune 2>/dev/null; done
    echo "🧹 pruned stale worktree metadata"
fi

echo
echo "Done. $removed worktree(s) removed."
