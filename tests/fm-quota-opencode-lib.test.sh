#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-opencode-lib.sh.
#
# Drives the public function fm_quota_opencode_enrich against snapshots on
# stdin, in an isolated FM_HOME so the cadence record is written to a temp
# state dir. The selection formula is pinned against a hand-computable gap and
# against the real quota-axi 0.1.47 opencode-go snapshot value, so a drift from
# quota-axi's pace.js scale is caught. No case touches the network or quota-axi.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-quota-opencode-lib.sh
. "$ROOT/bin/fm-quota-opencode-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-opencode)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state"
export FM_HOME="$HOME_DIR"

# enrich <snapshot-json> -> enriched JSON on stdout.
enrich() { printf '%s' "$1" | fm_quota_opencode_enrich; }

# --- a single-window scope has a hand-computable spendPriority ----------------
# generatedAt 00:00, rolling resetsAt 02:00 => 7200s remaining of the 18000s
# seed cycle => timeRemainingPercent 40. gap = 80/40 - (100-80)/(100-40)
#             = 2 - 0.33333 = 1.66667 -> 1.6667.
SINGLE='{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [ { "provider": "opencode-go", "state": { "status": "fresh" },
    "windows": [ { "id": "rolling", "kind": "unknown", "percentRemaining": 80, "resetsAt": "2030-01-01T02:00:00Z" } ],
    "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 80, "boundedBy": ["rolling"],
        "runway": { "status": "unknown" }, "selection": { "status": "unknown" } } ] } } ]
}'
sp=$(enrich "$SINGLE" | jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].selection.spendPriority')
assert_equals "1.6667" "$sp" "single-window spendPriority is the hand-computed gap"
st=$(enrich "$SINGLE" | jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].selection.status')
assert_equals "known" "$st" "filled selection status becomes known"
pass "single-window opencode-go scope gets a comparable, hand-verifiable spendPriority"

# --- the real quota-axi 0.1.47 opencode-go snapshot ranks (regression) --------
REAL='{
  "generatedAt": "2026-09-19T14:51:49.254Z",
  "schemaVersion": 5,
  "providers": [ { "provider": "opencode-go", "plan": "OpenCode Go", "state": { "status": "fresh", "stale": false },
    "windows": [
      { "id": "rolling", "kind": "unknown", "percentRemaining": 83, "resetsAt": "2026-09-19T15:03:01.621Z", "pace": { "status": "unknown", "reason": "missing_cycle" } },
      { "id": "weekly", "kind": "weekly", "percentRemaining": 69, "resetsAt": "2026-09-21T00:00:00.621Z", "pace": { "status": "unknown", "reason": "missing_cycle" } },
      { "id": "monthly", "kind": "monthly", "percentRemaining": 85, "resetsAt": "2026-10-17T07:29:34.621Z", "pace": { "status": "unknown", "reason": "missing_cycle" } } ],
    "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 69,
        "boundedBy": ["rolling", "weekly", "monthly"], "limitingWindowIds": ["weekly"],
        "runway": { "status": "unknown" }, "selection": { "status": "unknown", "unmeasurableWindowIds": ["rolling", "weekly", "monthly"] } } ] } } ]
}'
before=$(printf '%s' "$REAL" | jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].selection.spendPriority | type')
assert_equals "null" "$before" "before enrichment the real snapshot has no numeric spendPriority"
realsp=$(enrich "$REAL" | jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].selection.spendPriority')
assert_equals "-0.1212" "$realsp" "the real opencode-go snapshot resolves to the pinned seed-cycle spendPriority"
stale=$(enrich "$REAL" | jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].selection.unmeasurableWindowIds // "gone"')
assert_equals "gone" "$stale" "the stale unmeasurable window list is cleared from a filled row"
pass "the real quota-axi 0.1.47 opencode-go row goes from unranked to a numeric spendPriority"

# --- a selection quota-axi already resolved is never overwritten --------------
KNOWN=$(printf '%s' "$SINGLE" | jq '.providers[0].quotaSemantics.effectiveAvailability[0].selection = {status:"known", spendPriority: 0.42}')
kept=$(enrich "$KNOWN" | jq -r '.providers[0].quotaSemantics.effectiveAvailability[0].selection.spendPriority')
assert_equals "0.42" "$kept" "an already-resolved opencode-go spendPriority is left untouched"
pass "enrichment never overwrites a spendPriority quota-axi resolved itself"

# --- other providers and non-opencode snapshots pass through unchanged --------
OTHER='{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [ { "provider": "claude", "quotaSemantics": { "status": "known", "effectiveAvailability": [
    { "scope": "all_models", "status": "known", "effectivePercentRemaining": 50, "runway": { "status": "through_reset" }, "selection": { "status": "known", "spendPriority": 0.5 } } ] } } ]
}'
assert_equals "$(printf '%s' "$OTHER" | jq -S .)" "$(enrich "$OTHER" | jq -S .)" "a snapshot without opencode-go is unchanged"
pass "a snapshot without an unranked opencode-go row is passed through unchanged"

# --- garbage input is passed through unchanged (best effort) ------------------
GARBAGE='not json at all {'
assert_equals "$GARBAGE" "$(enrich "$GARBAGE")" "invalid input is echoed unchanged"
pass "invalid snapshot input never breaks the caller"

# --- the cadence record is created and accumulates distinct observations ------
rm -f "$HOME_DIR/state/quota-opencode-cadence.json"
enrich "$REAL" >/dev/null
assert_present "$HOME_DIR/state/quota-opencode-cadence.json" "the cadence record is created under state/"
n1=$(jq -r '.windows.weekly.samples | length' "$HOME_DIR/state/quota-opencode-cadence.json")
assert_equals "1" "$n1" "the first observation records one weekly sample"
# A second snapshot with a moved resetsAt adds a distinct sample; a repeat does not.
MOVED=$(printf '%s' "$REAL" | jq '.generatedAt="2026-09-21T01:00:00.000Z" | (.providers[0].windows[] | select(.id=="weekly").resetsAt) = "2026-09-28T00:00:00.621Z"')
enrich "$MOVED" >/dev/null
enrich "$REAL" >/dev/null
n2=$(jq -r '.windows.weekly.samples | length' "$HOME_DIR/state/quota-opencode-cadence.json")
assert_equals "2" "$n2" "a moved resetsAt adds one distinct sample; a repeat resetsAt does not"
pass "the cadence record persists distinct (observed_at, resetsAt) samples per window"

# --- an observed weekly reset jump refines the derived cycle ------------------
# The two weekly resetsAt above are exactly seven days apart, an in-band jump
# for the weekly seed, so the derived weekly cycle is 604800 seconds.
weekly_cycle=$(fm_quota_opencode_derive_cycles | jq -r '.weekly')
assert_equals "604800" "$weekly_cycle" "an observed seven-day reset jump derives the weekly cycle"
pass "the derived cycle self-corrects from an observed reset jump"

printf '# all fm-quota-opencode-lib tests passed\n'
