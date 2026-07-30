#!/usr/bin/env bash
# Behavioral tests for `grandma review`.
#
# Catches BUG #2: review.sh:52 referenced undefined $local_scope → the --apply dry-run
#   crashed under set -u.
# Catches BUG #3: review.sh:40 did `cut -d- -f1`, so a proposal for the kebab scope
#   `home-ops` resolved to scope `home` and loaded the wrong (nonexistent) memory.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home"; export SHELL=""
make_fixture_home "$GRANDMA_HOME"
PROP="$GRANDMA_HOME/proposals/home-ops-20260601T101010.md"

section "review — list"
capture env "$GBIN" review
assert_rc 0 "review (list) runs"
assert_contains "pending memory proposals: 1" "lists the one pending proposal"
assert_contains "home-ops-20260601T101010.md" "shows the proposal path"

section "review — filtered list by kebab scope"
capture env "$GBIN" review home-ops
assert_rc 0 "review home-ops runs"
assert_contains "home-ops-20260601T101010.md" "kebab filter matches the proposal"

section "review --apply dry-run (guards BUG #2 crash and BUG #3 wrong-scope)"
capture env GRANDMA_DRY_RUN=1 "$GBIN" review --apply "$PROP"
assert_rc 0 "review --apply dry-run runs under set -u (BUG #2: was \$local_scope unbound)"
# BUG #3: cut -d- -f1 yields 'home'; the correct scope is the whole 'home-ops'.
assert_contains "scope=home-ops" "resolves the FULL kebab scope, not a '-' truncation (BUG #3)"
assert_not_contains "scope=home)" "does not truncate home-ops to home (BUG #3)"

section "review --apply <scope> dry-run (apply ALL of a scope's pending proposals in one session)"
# Launch execs this when you accept the review-before-we-start offer. A second proposal proves
# it gathers every pending file for the scope, not just one.
PROP2="$GRANDMA_HOME/proposals/home-ops-20260601T202020.md"
cp "$PROP" "$PROP2"
capture env GRANDMA_DRY_RUN=1 "$GBIN" review --apply home-ops
assert_rc 0 "review --apply <scope> dry-run runs under set -u"
assert_contains "scope=home-ops" "resolves the FULL kebab scope for the scope-level apply"
assert_contains "home-ops-20260601T101010.md" "gathers the first pending proposal"
assert_contains "home-ops-20260601T202020.md" "gathers the second pending proposal (all, not one)"
rm -f "$PROP2"

section "review --apply <unknown> is a clean error, not a set -u crash"
capture env GRANDMA_DRY_RUN=1 "$GBIN" review --apply not-a-scope-or-file
assert_rc 1 "review --apply <bogus> exits 1"
assert_contains "no proposal to apply" "reports nothing to apply for an unknown arg"

section "review --clear (destructive; fixture is per-test)"
capture env "$GBIN" review --clear home-ops
assert_rc 0 "review --clear home-ops runs"
assert_contains "cleared 1 proposal(s)" "clears the matching proposal"
assert_no_file "$PROP" "proposal file is gone"
capture env "$GBIN" review --clear
assert_rc 0 "review --clear on empty runs"
assert_contains "no proposals to clear" "reports nothing to clear"

# ---- the nullglob stdin hang. Found live: `grandma <sweater>` offered to review a previous
# session, printed "opening review", and then sat there forever with no output and no way to tell
# why. review sets `shopt -s nullglob` before resolving the scope, and list_scopes globbed a
# media-only directory (assets/) down to NOTHING, which left `grep -lqE '^scope:'` with no file
# operand, so grep read stdin and blocked on the terminal.
#
# Reproduced without a pty: stdin is a fifo whose writer stays alive and never sends a byte, which is
# what a terminal looks like to a blocking read. Three details are load-bearing. The writer must
# outlive the cap, or the read stops blocking before the cap can judge it. It must not outlive it by
# much, because the blocked grep survives the capped parent and holds the capture pipe until the
# writer goes, so 8s against a 5s cap keeps a red run near 8s instead of a minute. And the writer is
# detached with its own output pointed away from ours: a plain `< <(sleep 8)` leaves a subshell
# holding this suite's stderr, which stalls anything reading the suite's log to EOF (CI does).
#
# Two sweater-less directories on purpose, one either side of the sweater alphabetically. Scope
# resolution stops reading list_scopes the moment the name it wants arrives, so a directory sorting
# after the sweater is never reached: with only a late one, the pre-fix code never hangs and this
# test would pass against the bug. `assets` is the real-world case, `zz-media` proves the guard is
# not just an artefact of sort order.
BLOCK="$TMP/block.fifo"; mkfifo "$BLOCK"
hold_stdin() { ( sleep 8 > "$BLOCK" 2>/dev/null & ) ; }   # one writer per case, then it lets go

mkdir -p "$GRANDMA_HOME/assets" "$GRANDMA_HOME/zz-media"
printf 'not markdown\n' > "$GRANDMA_HOME/assets/mascot.gif"
printf 'not markdown\n' > "$GRANDMA_HOME/zz-media/splash.gif"
{ echo "# grandma memory proposal"; echo "# scope=home-ops  transcript=abc123"; echo
  echo "target: home-ops/facts.md | action: append | text: recycling is biweekly"
} > "$PROP"   # --clear above emptied the queue; --apply needs something pending

section "list_scopes — a media-only directory does not send grep to stdin (nullglob-safe)"
hold_stdin
capture_capped 5 env GRANDMA_HOME="$GRANDMA_HOME" bash -c '
  set -uo pipefail; shopt -s nullglob
  ENGINE="'"$ENGINE"'"; ROOT="'"$GRANDMA_HOME"'"
  . "$ENGINE/lib/grandma-lib.sh"; list_scopes' < "$BLOCK"
assert_rc 0 "list_scopes returns under nullglob instead of blocking on stdin"
assert_contains "home-ops" "and still finds the real sweaters"
assert_not_contains "assets" "while leaving the media-only directory out"

section "review --apply <scope> — the path the launcher execs does not hang"
# The real symptom, not the dry run: `grandma <sweater>` execs exactly this when you accept the
# review offer, and it has to get all the way to launching the session. `claude` is stubbed with
# something that exits without touching stdin (the shared fake_claude drains stdin, which would
# swallow the very block we are testing for).
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/claude"; chmod +x "$TMP/bin/claude"
hold_stdin
capture_capped 5 env PATH="$TMP/bin:$PATH" GRANDMA_HOME="$GRANDMA_HOME" \
  "$GBIN" review --apply home-ops < "$BLOCK"
assert_rc 0 "review --apply reaches the review session instead of hanging on the terminal"

section "review --apply <scope> dry-run — same resolution, still no hang"
hold_stdin
capture_capped 5 env GRANDMA_DRY_RUN=1 "$GBIN" review --apply home-ops < "$BLOCK"
assert_rc 0 "the dry-run path resolves too"
assert_contains "scope=home-ops" "and still resolves the kebab scope"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_review: PASS"; else echo "cmd_review: $FAILS FAILURE(S)"; exit 1; fi
