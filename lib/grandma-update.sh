#!/usr/bin/env bash
#
# grandma-update — move the engine to the latest master, or print its version.
#
# The engine is a git checkout (install.sh clones it) and grandma tracks the repo's default
# branch as a rolling release, so an update always LANDS on that branch, whatever branch the
# checkout happens to be sitting on. That matters most for whoever develops grandma: parked on
# a feature branch, the old pull-the-current-branch version either died with a raw git error
# once the branch was merged and deleted upstream ("no such ref was fetched", while blaming
# local changes that did not exist) or, worse, printed a confident "already up to date" and
# exit 0 while master moved on without them.
#
# It fast-forwards only: never a force, never a history rewrite. Work you have not committed is
# refused rather than carried along or dropped, since landing on another branch is exactly how
# local edits disappear; --force stashes it first and prints the way back. `--version` (or
# `version`) just prints the running version. GRANDMA_DRY_RUN=1 prints the plan and touches
# nothing, so it never reaches the network.
set -uo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034  # ROOT is read by note_engine_updated / update_state_file in grandma-lib.sh
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"
source "$ENGINE/lib/grandma-lib.sh"

FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    version|--version|-v) printf 'grandma %s\n' "$(engine_version)"; exit 0 ;;
    --force|-f)           FORCE=1; shift ;;
    -h|--help)            printf '  usage: grandma update [--force]   (--force stashes local engine changes first)\n'; exit 0 ;;
    *) printf '  unknown option: %s\n' "$1" >&2
       printf '  usage: grandma update [--force]   (--force stashes local engine changes first)\n' >&2
       exit 1 ;;
  esac
done

git_e() { git -C "$ENGINE" "$@"; }

# same_path — compare two paths by what they physically are, so a symlinked engine (or macOS
# /var vs /private/var) does not read as a different directory.
same_path() {
  local a b
  a="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  b="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  [[ "$a" == "$b" ]]
}

if ! engine_is_git; then
  printf '  this grandma engine is not a git checkout (%s), so there is nothing to pull.\n' "$ENGINE" >&2
  printf '  reinstall to update — the one-line installer is in the grandma README.\n' >&2
  exit 1
fi

# engine_is_git asks git, and git walks UP. A plain copy of the engine dropped inside another
# repository (a zip download into a project, or a $HOME that is itself a dotfiles repo) answers
# yes, and then every command below would fetch and switch branches in THAT repo, silently
# rearranging someone else's working tree while reporting that grandma had been updated.
TOP="$(git_e rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$TOP" ]] || ! same_path "$TOP" "$ENGINE"; then
  printf '  %s is not the root of a git checkout' "$ENGINE" >&2
  [[ -n "$TOP" ]] && printf ' (it sits inside the repo at %s)' "$TOP" >&2
  printf ', so grandma will not update it.\n' >&2
  printf '  reinstall to update — the one-line installer is in the grandma README.\n' >&2
  exit 1
fi

# tracked_branch — the branch grandma follows, as the REMOTE reports it. origin/HEAD is written
# once at clone time and a plain fetch never revisits it, so it can point at a branch that has
# since been deleted or renamed: `remote set-head --auto` (run just after the fetch) is what makes
# this current. The master/main fallback only covers a remote that answers nothing at all.
tracked_branch() {
  local cand b
  cand="$(git_e symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" || cand=""
  cand="${cand#origin/}"
  # A --depth 1 clone (what install.sh makes) is single-branch: its refspec fetches only the
  # branch it cloned, so a default branch renamed upstream has no local ref until asked for.
  if [[ -n "$cand" ]] && ! git_e show-ref --verify --quiet "refs/remotes/origin/$cand"; then
    git_e fetch origin "+refs/heads/$cand:refs/remotes/origin/$cand" >/dev/null 2>&1 || true
  fi
  for b in "$cand" master main; do
    [[ -n "$b" ]] || continue
    if git_e show-ref --verify --quiet "refs/remotes/origin/$b"; then printf '%s' "$b"; return 0; fi
  done
  return 1
}

branch_before="$(git_e rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ "$branch_before" == "HEAD" ]] && branch_before=""   # detached: no branch to name or return to

if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
  # No fetch, so this reads the local cache and may not know the branch yet. Say so rather than
  # naming a default that the real run might not agree with.
  target="$(tracked_branch || true)"
  if [[ -n "$target" ]]; then _plan="origin/$target"; else _plan="origin's default branch"; fi
  printf '  would run: git -C %s fetch --prune origin, then fast-forward onto %s\n' "$ENGINE" "$_plan" >&2
  [[ "$FORCE" == "1" ]] && printf '  --force: any uncommitted changes to tracked files would be stashed first\n' >&2
  printf '  current:   grandma %s on branch %s\n' "$(engine_version)" "${branch_before:-a detached HEAD}" >&2
  exit 0
fi

printf '  updating grandma engine at %s ...\n' "$ENGINE" >&2
if ! git_e fetch --prune origin; then
  printf '  could not fetch from origin. Check your network or your git credentials, then retry.\n' >&2
  exit 1
fi
git_e remote set-head origin --auto >/dev/null 2>&1 || true   # refresh origin/HEAD, see tracked_branch

if ! target="$(tracked_branch)"; then
  printf '  cannot tell which branch to track: origin reports no default branch and has no master or main.\n' >&2
  printf '  point it at one with: git -C %s remote set-head origin -a\n' "$ENGINE" >&2
  exit 1
fi

# Never rewrite history. If the local branch carries commits origin does not have, this is not a
# fast-forward, so stop rather than move the branch ref out from under them. Checked before the
# stash below, so a refusal never leaves the user's work parked in a stash they did not expect.
if git_e show-ref --verify --quiet "refs/heads/$target" \
   && ! git_e merge-base --is-ancestor "refs/heads/$target" "refs/remotes/origin/$target"; then
  printf '  local %s has commits that are not on origin/%s, so this is not a fast-forward.\n' \
    "$target" "$target" >&2
  printf '  grandma update never rewrites history. Push those commits or move them to a branch, then retry.\n' >&2
  exit 1
fi

# git refuses `checkout <branch>` when another worktree already holds that branch, but it does NOT
# refuse `checkout -B`. Doing it anyway leaves two worktrees claiming one branch, and the other
# one's index then reads as a staged revert of whatever we just fast-forwarded past.
_wt=""; other_wt=""
while IFS= read -r _line; do
  case "$_line" in
    worktree\ *) _wt="${_line#worktree }" ;;
    branch\ refs/heads/*)
      if [[ "${_line#branch refs/heads/}" == "$target" ]] && ! same_path "$_wt" "$ENGINE"; then
        other_wt="$_wt"
      fi ;;
  esac
done < <(git_e worktree list --porcelain 2>/dev/null || true)
if [[ -n "$other_wt" ]]; then
  printf '  %s is checked out in another worktree (%s), so moving this one onto it would leave both\n' \
    "$target" "$other_wt" >&2
  printf '  claiming the same branch. Update from that worktree instead, or remove it first.\n' >&2
  exit 1
fi

# A detached HEAD carrying its own commits (mid-bisect, or a commit made on a checked-out tag) has
# no branch to keep them alive, and -q hides git's own warning about leaving them behind.
if [[ -z "$branch_before" ]]; then
  _head="$(git_e rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$_head" ]] && ! git_e merge-base --is-ancestor "$_head" "refs/remotes/origin/$target"; then
    printf '  the engine is on a detached HEAD at %s, holding work that is not on %s.\n' \
      "${_head:0:12}" "$target" >&2
    printf '  keep it first (git -C %s branch <name> %s), then run update again.\n' \
      "$ENGINE" "${_head:0:12}" >&2
    exit 1
  fi
fi

# Only TRACKED changes block the update: an untracked scratch file is not at risk from landing on
# another branch (git refuses the checkout itself if one would be overwritten), and sweeping it
# into a stash would hide a file the user never asked us to touch.
stashed=0
dirty="$(git_e status --porcelain --untracked-files=no 2>/dev/null)"
if [[ -n "$dirty" ]]; then
  if [[ "$FORCE" != "1" ]]; then
    printf '  the engine has uncommitted changes to tracked files, so nothing was touched:\n' >&2
    printf '%s\n' "$dirty" | head -n 5 | sed 's/^/    /' >&2
    [[ "$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')" -gt 5 ]] && printf '    ...\n' >&2
    printf '  commit or stash them yourself, or run: grandma update --force  (stashes them for you)\n' >&2
    exit 1
  fi
  if ! git_e stash push --message "grandma update $(date +%Y-%m-%dT%H-%M-%S)"; then
    printf '  --force could not stash the local changes, so nothing was touched.\n' >&2
    exit 1
  fi
  stashed=1
fi

before="$(git_e rev-parse --short HEAD 2>/dev/null)"

# One git operation, not a checkout followed by a pull: landing on the old local branch tip first
# would rewrite the engine's files twice, and a running grandma reads its own scripts incrementally
# by byte offset, so a mid-session shuffle can crash a live session on a line neither version has.
if ! git_e checkout -q -B "$target" "origin/$target"; then
  printf '  could not move the engine onto %s.\n' "$target" >&2
  [[ "$stashed" == "1" ]] && \
    printf '  your changes are still stashed (git -C %s stash list) — restore with: git stash pop\n' "$ENGINE" >&2
  exit 1
fi
git_e branch --set-upstream-to "origin/$target" "$target" >/dev/null 2>&1 || true

after="$(git_e rev-parse --short HEAD 2>/dev/null)"
note_engine_updated   # reset the staleness nudge

if [[ -n "$branch_before" && "$branch_before" != "$target" ]]; then
  printf '  engine was on branch %s, now on %s — that branch is untouched: git -C %s checkout %s\n' \
    "$branch_before" "$target" "$ENGINE" "$branch_before" >&2
fi
[[ "$stashed" == "1" ]] && \
  printf '  your uncommitted changes are stashed (git -C %s stash list) — bring them back on whichever\n  branch you want them with: git -C %s stash pop\n' "$ENGINE" "$ENGINE" >&2

if [[ "$before" == "$after" ]]; then
  printf '  already up to date — grandma %s\n' "$(engine_version)" >&2
else
  printf '  updated grandma: %s -> %s\n\n' "$before" "$after" >&2
  if [[ -f "$ENGINE/CHANGELOG.md" ]]; then
    printf '  what changed (top of CHANGELOG.md):\n' >&2
    # print the first ## section (heading + body), stop at the next ##
    awk 'BEGIN{c=0} /^## /{c++} c==1{print "    " $0} c==2{exit}' "$ENGINE/CHANGELOG.md" >&2
  fi
fi
