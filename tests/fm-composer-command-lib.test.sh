#!/usr/bin/env bash
# tests/fm-composer-command-lib.test.sh - unit tests for the default-off
# composer command-invocation delivery library (bin/fm-composer-command-lib.sh):
# recognition/allowlist, session capture bound to the session lock, the
# busy/composer delivery guard, the submit-confirm gate, and the
# idempotency/restart-safety contract, for both the tmux and Orca delivery
# paths. Fakes tmux's target-exists probe and stubs each backend's delivery
# primitives (tmux: fm_pane_is_busy, fm_tmux_composer_state,
# fm_tmux_submit_core; Orca: fm_backend_orca_capture,
# fm_backend_orca_rendered_busy_state, fm_backend_orca_composer_state,
# fm_backend_orca_send_text_submit) rather than driving a real pty or Orca
# terminal, so this suite is fast and deterministic; PR evidence records a
# real end-to-end Orca demonstration; tests/fm-composer-command-inbox.test.sh
# covers the bin/fm-inbox.sh arrival path this library plugs into.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-command-lib.sh"

WORK=$(fm_test_tmproot fm-composer-command)

# --- recognition rule: exact allowlist match only ----------------------------

fm_composer_command_match "/compact" >/dev/null || fail "the exact allowlisted command must match"
pass "fm_composer_command_match accepts the exact allowlisted command"

for bad in \
  "/compact now" \
  "please /compact" \
  "/compact --force" \
  "/Compact" \
  "/compac" \
  "/compactt" \
  $'/compact\nrm -rf /' \
  "" \
  "  " ; do
  if out=$(fm_composer_command_match "$bad" 2>/dev/null); then
    fail "must not match a non-exact invocation: '$bad' (matched '$out')"
  fi
done
pass "fm_composer_command_match rejects arguments, prose, case changes, prefixes, extra lines, and empty/whitespace text"

trimmed=$(fm_composer_command_match "  /compact
")
[ "$trimmed" = "/compact" ] || fail "surrounding whitespace/newlines must be trimmed before matching"
pass "fm_composer_command_match trims only leading/trailing whitespace, not internal content"

if fm_composer_command_match "/rm -rf /" >/dev/null 2>&1; then
  fail "an unlisted command-shaped string must never match"
fi
pass "a command-shaped string outside the allowlist never matches"

# --- enablement: default-off presence flag -----------------------------------

CFG_OFF="$WORK/cfg-off"; CFG_ON="$WORK/cfg-on"
mkdir -p "$CFG_OFF" "$CFG_ON"
: > "$CFG_ON/composer-commands"

fm_composer_command_enabled "$CFG_OFF" && fail "absent config/composer-commands must be off by default"
fm_composer_command_enabled "$CFG_ON" || fail "present config/composer-commands must enable"
pass "composer command delivery is off by default and on only when config/composer-commands is present"

# --- session capture: certainty only, bound to the session lock -------------

# No ambient supervisor/tmux/herdr/orca signal must leak into this section
# from the host shell (this suite may itself run inside a real tmux pane or a
# real Orca terminal); each case below sets exactly the signal it needs on the
# call that consumes it.
unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND HERDR_ENV HERDR_PANE_ID TMUX_PANE ORCA_TERMINAL_HANDLE

STATE1="$WORK/state1"
mkdir -p "$STATE1"
printf '101\n' > "$STATE1/.lock"

# Disabled: session_start must not create a durable record even with a
# resolvable pane, so a captain who has not opted in leaves no new state.
TMUX_PANE="%42" fm_composer_command_session_start "$CFG_OFF" "$STATE1"
[ ! -e "$STATE1/.composer-session-target" ] || fail "session_start must record nothing while the feature is disabled"
pass "session_start writes no durable record while config/composer-commands is absent"

# Enabled + resolvable pane: must capture with certainty and become effective
# under the SAME session lock.
TMUX_PANE="%42" fm_composer_command_session_start "$CFG_ON" "$STATE1"
eff=$(fm_composer_command_session_effective "$STATE1") \
  || fail "an enabled, resolvable capture must become effective"
read -r eff_backend eff_target <<< "$eff"
[ "$eff_backend" = tmux ] && [ "$eff_target" = "%42" ] \
  || fail "effective record must be exactly the captured tmux pane (got backend=$eff_backend target=$eff_target)"
pass "session_start captures a confidently-resolved tmux pane and session_effective reads it back verbatim"

# Enabled but NOT resolvable with certainty (no TMUX_PANE, no herdr env, no
# override): must record nothing, never the bare legacy-default guess.
STATE2="$WORK/state2"
mkdir -p "$STATE2"
printf '202\n' > "$STATE2/.lock"
fm_composer_command_session_start "$CFG_ON" "$STATE2"
[ ! -e "$STATE2/.composer-session-target" ] || fail "an uncertain resolution must never be recorded"
if fm_composer_command_session_effective "$STATE2" >/dev/null 2>&1; then
  fail "session_effective must fail with no confident record"
fi
pass "session_start never records the uncertain legacy-default guess, and session_effective refuses without a confident record"

# Restart safety: a new session (new lock pid) invalidates the PRIOR session's
# record even though the file on disk is untouched, so a stale pane from a
# superseded session can never be resolved as current.
printf '999\n' > "$STATE1/.lock"
if fm_composer_command_session_effective "$STATE1" >/dev/null 2>&1; then
  fail "a record bound to a superseded session lock must not resolve as effective"
fi
pass "a durable session record from a prior (now-superseded) session lock is never trusted as current"

# --- fm_composer_command_deliver: full pipeline, tmux/session primitives faked

FAKEBIN=$(fm_fakebin "$WORK")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
# Only the one call fm_composer_command_deliver makes directly: the
# target-exists probe. FM_TEST_TMUX_TARGET_EXISTS controls its verdict.
if [ "${FM_TEST_TMUX_TARGET_EXISTS:-1}" = 1 ]; then
  echo '%42'
  exit 0
fi
exit 1
SH
chmod +x "$FAKEBIN/tmux"
PATH="$FAKEBIN:$PATH"
export PATH

# Deterministic stand-ins for the tmux delivery primitives this library reuses
# rather than reinventing (bin/fm-tmux-lib.sh). Each is driven by an env var so
# every pipeline branch below is exercised without a real pty.
fm_pane_is_busy() { [ "${FM_TEST_PANE_BUSY:-0}" = 1 ]; }
fm_tmux_composer_state() { printf '%s' "${FM_TEST_COMPOSER_STATE:-empty}"; }
# shellcheck disable=SC2329 # invoked indirectly, via fm_composer_command_deliver in the sourced lib
fm_tmux_submit_core() { printf '%s' "${FM_TEST_SUBMIT_VERDICT:-empty}"; }

STATE3="$WORK/state3"
mkdir -p "$STATE3"
printf '303\n' > "$STATE3/.lock"
unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND HERDR_ENV HERDR_PANE_ID ORCA_TERMINAL_HANDLE
TMUX_PANE="%42" fm_composer_command_session_start "$CFG_ON" "$STATE3"

out=$(fm_composer_command_deliver "please /compact this" "k-notacmd" "$CFG_OFF" "$STATE3"); rc=$?
[ "$rc" -eq 2 ] || fail "disabled must return rc=2, got $rc: $out"
pass "deliver refuses with rc=2 when the feature is disabled, regardless of text"

out=$(fm_composer_command_deliver "please /compact this" "k-notacmd" "$CFG_ON" "$STATE3"); rc=$?
[ "$rc" -eq 3 ] || fail "an unrecognized invocation must return rc=3, got $rc: $out"
pass "deliver refuses with rc=3 for a note that is not an exact allowlisted command"

out=$(FM_TEST_PANE_BUSY=1 fm_composer_command_deliver "/compact" "k-busy" "$CFG_ON" "$STATE3"); rc=$?
[ "$rc" -eq 8 ] || fail "a busy pane must defer with rc=8, got $rc: $out"
[ ! -e "$STATE3/.composer-command-delivered/k-busy" ] || fail "a deferred (busy) attempt must not be marked delivered"
pass "deliver defers (rc=8) and marks nothing delivered when the session is busy"

out=$(FM_TEST_COMPOSER_STATE=pending fm_composer_command_deliver "/compact" "k-pending" "$CFG_ON" "$STATE3"); rc=$?
[ "$rc" -eq 8 ] || fail "a non-empty composer must defer with rc=8, got $rc: $out"
pass "deliver defers (rc=8) when the composer is not confirmed empty"

out=$(FM_TEST_SUBMIT_VERDICT=pending fm_composer_command_deliver "/compact" "k-unconfirmed" "$CFG_ON" "$STATE3"); rc=$?
[ "$rc" -eq 9 ] || fail "an unconfirmed submit must return rc=9, got $rc: $out"
[ ! -e "$STATE3/.composer-command-delivered/k-unconfirmed" ] || fail "an unconfirmed submit must not be marked delivered"
pass "deliver reports rc=9 and marks nothing delivered when the submit cannot be confirmed"

out=$(FM_TEST_TMUX_TARGET_EXISTS=0 fm_composer_command_deliver "/compact" "k-gone" "$CFG_ON" "$STATE3"); rc=$?
[ "$rc" -eq 7 ] || fail "a gone endpoint must return rc=7, got $rc: $out"
pass "deliver reports rc=7 when this home's own recorded session endpoint no longer exists"

out=$(fm_composer_command_deliver "/compact" "k-unresolved" "$CFG_ON" "$STATE1"); rc=$?
[ "$rc" -eq 5 ] || fail "an unresolvable session must return rc=5, got $rc: $out (STATE1 lock was superseded above)"
pass "deliver reports rc=5 when this home's own session cannot be resolved with certainty"

out=$(fm_composer_command_deliver "/compact" "k-ok" "$CFG_ON" "$STATE3"); rc=$?
[ "$rc" -eq 0 ] || fail "a clean idle delivery must succeed with rc=0, got $rc: $out"
assert_present "$STATE3/.composer-command-delivered/k-ok" "a confirmed submit must write the idempotency marker"
pass "deliver succeeds (rc=0) and marks the key delivered once the submit is confirmed"

# --- idempotency / restart safety: never delivered twice ---------------------

CALLS_FILE="$WORK/submit-calls"
: > "$CALLS_FILE"
# shellcheck disable=SC2329 # invoked indirectly, via fm_composer_command_deliver in the sourced lib
fm_tmux_submit_core() { printf 'x' >> "$CALLS_FILE"; printf '%s' empty; }

out=$(fm_composer_command_deliver "/compact" "k-ok" "$CFG_ON" "$STATE3"); rc=$?
[ "$rc" -eq 0 ] || fail "a repeat call for an already-delivered key must still succeed (idempotent), got $rc: $out"
[ ! -s "$CALLS_FILE" ] || fail "an already-delivered key must never re-invoke the submit primitive"
pass "a second delivery attempt for the same key is a no-op success and never re-submits"

# Simulate a restart: a fresh process re-sources the library (no in-memory
# state) and points at the SAME durable state dir. The marker on disk is what
# must prevent a resend, not anything held only in this process.
(
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-composer-command-lib.sh"
  # shellcheck disable=SC2329 # invoked indirectly, via fm_composer_command_deliver in the sourced lib
  fm_tmux_submit_core() { echo -n x >> "$CALLS_FILE"; printf '%s' empty; }
  out=$(fm_composer_command_deliver "/compact" "k-ok" "$CFG_ON" "$STATE3"); rc=$?
  [ "$rc" -eq 0 ] || { echo "not ok - restart replay must still report success, got $rc: $out" >&2; exit 1; }
)
[ ! -s "$CALLS_FILE" ] || fail "a restart-simulated re-delivery for an already-delivered key must never resend"
pass "the delivered marker survives a simulated restart, so the same key is never delivered twice"

# --- marker write failure after a confirmed submit must not claim success ---
# The command has already run at this point (submit was confirmed). A live
# failure writing its durable marker (a read-only marker directory here, not
# a process crash) must be reported loudly and distinctly, never swallowed
# into an ordinary success - silently claiming success would leave a later
# same-key call free to resubmit the same command.

WRITEFAIL_KEY="k-writefail"
mkdir -p "$STATE3/.composer-command-delivered"
chmod 0500 "$STATE3/.composer-command-delivered"
out=$(fm_composer_command_deliver "/compact" "$WRITEFAIL_KEY" "$CFG_ON" "$STATE3"); rc=$?
chmod 0700 "$STATE3/.composer-command-delivered"
[ "$rc" -eq 10 ] || fail "a marker write failure after a confirmed submit must report rc=10, got $rc: $out"
assert_contains "$out" "durable delivered-marker could not be written" \
  "a marker write failure must be reported, never silently claimed as success"
[ ! -e "$STATE3/.composer-command-delivered/$WRITEFAIL_KEY" ] \
  || fail "the marker must not exist when its write genuinely failed"
pass "a marker write failure after a confirmed submit is reported loudly (rc=10), never claimed as durable success"

# Once the marker path is writable again, the SAME key must still be treated
# as undelivered (free to retry) rather than permanently stuck or falsely
# marked delivered by the failed attempt.
out=$(fm_composer_command_deliver "/compact" "$WRITEFAIL_KEY" "$CFG_ON" "$STATE3"); rc=$?
[ "$rc" -eq 0 ] || fail "a retry after the marker directory is writable again must succeed, got $rc: $out"
assert_present "$STATE3/.composer-command-delivered/$WRITEFAIL_KEY" \
  "a successful retry must finally write the marker"
pass "once the marker path is writable again, a same-key retry succeeds and finally records delivery"

# --- concurrent in-flight claim: no double-send race -------------------------

CLAIM_KEY="k-inflight"
mkdir -p "$STATE3/.composer-command-inflight"
mkdir "$STATE3/.composer-command-inflight/$CLAIM_KEY"
out=$(fm_composer_command_deliver "/compact" "$CLAIM_KEY" "$CFG_ON" "$STATE3"); rc=$?
[ "$rc" -eq 4 ] || fail "a live concurrent claim must refuse with rc=4, got $rc: $out"
rmdir "$STATE3/.composer-command-inflight/$CLAIM_KEY" 2>/dev/null || true
pass "deliver refuses rc=4 rather than racing an in-flight attempt for the same key"

# --- Orca session capture: ORCA_TERMINAL_HANDLE mirrors TMUX_PANE -----------

STATE4="$WORK/state4"
mkdir -p "$STATE4"
printf '404\n' > "$STATE4/.lock"
unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND HERDR_ENV HERDR_PANE_ID TMUX_PANE

ORCA_TERMINAL_HANDLE="term_abc-123" fm_composer_command_session_start "$CFG_ON" "$STATE4"
eff=$(fm_composer_command_session_effective "$STATE4") \
  || fail "an enabled, resolvable Orca capture must become effective"
read -r eff_backend eff_target <<< "$eff"
[ "$eff_backend" = orca ] && [ "$eff_target" = "term_abc-123" ] \
  || fail "effective record must be exactly the captured Orca terminal handle (got backend=$eff_backend target=$eff_target)"
pass "session_start captures a confidently-resolved Orca terminal handle and session_effective reads it back verbatim"

# Absent ORCA_TERMINAL_HANDLE (and no other signal) is the same uncertain case
# already proven generically above (STATE2) - re-prove it here scoped to the
# Orca signal specifically, so an absent/empty handle can never be confused
# with a confident capture.
STATE5="$WORK/state5"
mkdir -p "$STATE5"
printf '505\n' > "$STATE5/.lock"
ORCA_TERMINAL_HANDLE='' fm_composer_command_session_start "$CFG_ON" "$STATE5"
[ ! -e "$STATE5/.composer-session-target" ] || fail "an absent ORCA_TERMINAL_HANDLE must never be recorded"
if fm_composer_command_session_effective "$STATE5" >/dev/null 2>&1; then
  fail "session_effective must fail with no confident Orca signal"
fi
pass "session_start never records an absent/empty ORCA_TERMINAL_HANDLE, and session_effective refuses without it"

# --- fm_composer_command_deliver: Orca dispatch, backend/session primitives faked

# Deterministic stand-ins for the Orca delivery primitives this library reuses
# rather than reinventing (bin/backends/orca.sh). Each is driven by an env var
# so every pipeline branch below is exercised without a real Orca terminal.
FM_TEST_ORCA_CAPTURE_CALLS="$WORK/orca-capture-calls"
FM_TEST_ORCA_SUBMIT_CALLS="$WORK/orca-submit-calls"
FM_TEST_TMUX_SUBMIT_CALLS="$WORK/tmux-submit-calls"
: > "$FM_TEST_ORCA_CAPTURE_CALLS"
: > "$FM_TEST_ORCA_SUBMIT_CALLS"
: > "$FM_TEST_TMUX_SUBMIT_CALLS"
# shellcheck disable=SC2329 # invoked indirectly, via fm_composer_command_deliver in the sourced lib
fm_backend_orca_capture() {
  printf 'x' >> "$FM_TEST_ORCA_CAPTURE_CALLS"
  [ "${FM_TEST_ORCA_TARGET_EXISTS:-1}" = 1 ] || return 1
  printf ''
}
# shellcheck disable=SC2329 # invoked indirectly, via fm_composer_command_deliver in the sourced lib
fm_backend_orca_rendered_busy_state() { [ "${FM_TEST_ORCA_BUSY:-0}" = 1 ] && printf 'busy' || printf 'idle'; }
# shellcheck disable=SC2329 # invoked indirectly, via fm_composer_command_deliver in the sourced lib
fm_backend_orca_composer_state() { printf '%s' "${FM_TEST_ORCA_COMPOSER_STATE:-empty}"; }
# shellcheck disable=SC2329 # invoked indirectly, via fm_composer_command_deliver in the sourced lib
fm_backend_orca_send_text_submit() {
  printf 'x' >> "$FM_TEST_ORCA_SUBMIT_CALLS"
  printf '%s' "${FM_TEST_ORCA_SUBMIT_VERDICT:-empty}"
}
# Reused tmux stand-in from above, now counting calls so the two backends'
# dispatch can be told apart by which counter moved.
fm_tmux_submit_core() { printf 'x' >> "$FM_TEST_TMUX_SUBMIT_CALLS"; printf '%s' "${FM_TEST_SUBMIT_VERDICT:-empty}"; }

STATE6="$WORK/state6"
mkdir -p "$STATE6"
printf '606\n' > "$STATE6/.lock"
unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND HERDR_ENV HERDR_PANE_ID TMUX_PANE
ORCA_TERMINAL_HANDLE="term_abc-123" fm_composer_command_session_start "$CFG_ON" "$STATE6"

out=$(FM_TEST_ORCA_BUSY=1 fm_composer_command_deliver "/compact" "k-orca-busy" "$CFG_ON" "$STATE6"); rc=$?
[ "$rc" -eq 8 ] || fail "an Orca terminal reading busy must defer with rc=8, got $rc: $out"
[ ! -e "$STATE6/.composer-command-delivered/k-orca-busy" ] || fail "a deferred (busy) Orca attempt must not be marked delivered"
pass "deliver defers (rc=8) via the Orca busy primitive when the recorded backend is orca"

out=$(FM_TEST_ORCA_COMPOSER_STATE=pending fm_composer_command_deliver "/compact" "k-orca-pending" "$CFG_ON" "$STATE6"); rc=$?
[ "$rc" -eq 8 ] || fail "a non-empty Orca composer must defer with rc=8, got $rc: $out"
pass "deliver defers (rc=8) via the Orca composer-state primitive when it is not confirmed empty"

out=$(FM_TEST_ORCA_TARGET_EXISTS=0 fm_composer_command_deliver "/compact" "k-orca-gone" "$CFG_ON" "$STATE6"); rc=$?
[ "$rc" -eq 7 ] || fail "a gone Orca endpoint must return rc=7, got $rc: $out"
pass "deliver reports rc=7 via the Orca existence primitive when the terminal no longer exists"

out=$(FM_TEST_ORCA_SUBMIT_VERDICT=pending fm_composer_command_deliver "/compact" "k-orca-unconfirmed" "$CFG_ON" "$STATE6"); rc=$?
[ "$rc" -eq 9 ] || fail "an unconfirmed Orca submit must return rc=9, got $rc: $out"
[ ! -e "$STATE6/.composer-command-delivered/k-orca-unconfirmed" ] || fail "an unconfirmed Orca submit must not be marked delivered"
pass "deliver reports rc=9 and marks nothing delivered when the Orca submit cannot be confirmed"

: > "$FM_TEST_ORCA_SUBMIT_CALLS"
: > "$FM_TEST_TMUX_SUBMIT_CALLS"
out=$(fm_composer_command_deliver "/compact" "k-orca-ok" "$CFG_ON" "$STATE6"); rc=$?
[ "$rc" -eq 0 ] || fail "a clean idle Orca delivery must succeed with rc=0, got $rc: $out"
assert_present "$STATE6/.composer-command-delivered/k-orca-ok" "a confirmed Orca submit must write the idempotency marker"
[ -s "$FM_TEST_ORCA_SUBMIT_CALLS" ] || fail "delivering through the orca-bound session must invoke the Orca submit primitive"
[ ! -s "$FM_TEST_TMUX_SUBMIT_CALLS" ] || fail "delivering through the orca-bound session must never invoke the tmux submit primitive"
pass "deliver dispatches through the Orca primitives (not tmux) when the recorded backend is orca"

# Idempotent replay on the Orca path: a repeat call for the same key must
# never re-invoke the Orca submit primitive, mirroring the tmux idempotency
# contract proven above.
: > "$FM_TEST_ORCA_SUBMIT_CALLS"
out=$(fm_composer_command_deliver "/compact" "k-orca-ok" "$CFG_ON" "$STATE6"); rc=$?
[ "$rc" -eq 0 ] || fail "a repeat call for an already-delivered Orca key must still succeed (idempotent), got $rc: $out"
[ ! -s "$FM_TEST_ORCA_SUBMIT_CALLS" ] || fail "an already-delivered Orca key must never re-invoke the submit primitive"
pass "a second Orca delivery attempt for the same key is a no-op success and never re-submits"

# Cross-check: delivering through the ORIGINAL tmux-bound session (STATE3)
# still dispatches through tmux, not Orca, proving the two backends stay
# independently routed rather than one silently winning.
: > "$FM_TEST_ORCA_SUBMIT_CALLS"
: > "$FM_TEST_TMUX_SUBMIT_CALLS"
out=$(fm_composer_command_deliver "/compact" "k-tmux-cross-check" "$CFG_ON" "$STATE3"); rc=$?
[ "$rc" -eq 0 ] || fail "a clean idle tmux delivery must still succeed with rc=0, got $rc: $out"
[ -s "$FM_TEST_TMUX_SUBMIT_CALLS" ] || fail "delivering through the tmux-bound session must invoke the tmux submit primitive"
[ ! -s "$FM_TEST_ORCA_SUBMIT_CALLS" ] || fail "delivering through the tmux-bound session must never invoke the Orca submit primitive"
pass "deliver dispatches through the tmux primitives (not Orca) when the recorded backend is tmux"

echo "# fm-composer-command-lib.test.sh: all assertions passed"
