#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-outward-text-lint.sh"
TMP_ROOT=$(fm_test_tmproot fm-outward-text-lint)

lint_text() { # <text> [lint args...]: print stderr, return the exit code
  local text=$1
  shift
  printf '%s\n' "$text" | "$SCRIPT" "$@" 2>&1
}

assert_flagged() { # <rule> <text> [lint args...]
  local rule=$1 text=$2 out rc
  shift 2
  out=$(lint_text "$text" "$@") && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "text was not flagged by rule $rule: $text"
  assert_contains "$out" "RULE $rule" "rule $rule not named for: $text"
  assert_contains "$out" 'fix:' "no fix hint for: $text"
}

assert_clean() { # <text> [lint args...]
  local text=$1 out rc
  shift
  out=$(lint_text "$text" "$@") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "clean text was flagged: $text -> $out"
}

test_rule_a_words() {
  assert_flagged A 'Apply the Captain decision.'
  assert_flagged A 'handed to FIRSTMATE for review'
  assert_flagged A 'the first mate approved it'
  assert_flagged A 'the first-mate approved it'
  assert_flagged A 'captains of the fleet'
  assert_flagged A '(captain)'
  pass "rule A flags captain, firstmate, and first mate in any case and spacing"
}

test_rule_a_does_not_flag_unrelated_words() {
  assert_clean 'the captaincy rotation and a firstmatez token'
  assert_clean 'first matches the second mated pair'
  pass "rule A is word-bounded and ignores unrelated words"
}

test_rule_a_reports_line_numbers() {
  local out
  out=$(lint_text $'clean\nsecond line\nthe captain said' || true)
  assert_contains "$out" 'line 3' "the offending line number is missing"
  assert_not_contains "$out" 'line 2' "a clean line was reported"
  pass "rule A names only the offending line numbers"
}

test_rule_p_paths() {
  assert_flagged P 'built in /home/someone/work/repo'
  assert_flagged P 'built in /Users/someone/work/repo'
  assert_flagged P 'see ~/.treehouse/pool/1'
  assert_flagged P 'see /srv/x/.treehouse/pool/1'
  assert_flagged P 'cat /srv/firstmate/state/task.status'
  assert_flagged P 'cat /srv/firstmate-two/data/task/report.md'
  assert_clean 'use /home/<user>/ as a placeholder and bin/fm-spawn.sh'
  assert_clean 'the state/ directory holds runtime records'
  pass "rule P flags private machine paths and ignores placeholders"
}

test_rule_t_tokens() {
  local out
  assert_flagged T 'https://example.test/o#orderLinkToken=abcdef1234567890'
  assert_flagged T 'https://example.test/o?x=1&order_link_token=abcdef1234567890'
  assert_flagged T 'https://example.test/o?api_key=abcdef1234567890'
  assert_clean 'https://example.test/o#orderLinkToken=<value>'
  assert_clean 'https://example.test/o?page=2&sort=asc'
  out=$(lint_text 'https://example.test/o#orderLinkToken=abcdef1234567890' || true)
  assert_not_contains "$out" 'abcdef1234567890' "the diagnostic echoed the token"
  pass "rule T flags secret tokens in a query or fragment without echoing them"
}

test_commit_message_mode() {
  assert_clean $'fix: subject\n\n# The captain wrote this git comment line' --commit-msg
  assert_clean $'fix: subject\n# ------------------------ >8 ------------------------\ncaptain in the diff' --commit-msg
  assert_flagged A $'fix: subject\n\nthe captain asked' --commit-msg
  pass "commit-message mode ignores git comment lines and the scissors section"
}

test_input_modes_and_usage() {
  local file out rc
  file="$TMP_ROOT/in.txt"
  printf 'the captain\n' > "$file"
  out=$("$SCRIPT" --label 'PR description' "$file" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a file input was not linted"
  assert_contains "$out" 'PR description' "the label is missing from the diagnostic"
  out=$("$SCRIPT" "$TMP_ROOT/missing.txt" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unreadable file did not exit 2"
  out=$("$SCRIPT" --bogus 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown flag did not exit 2"
  out=$("$SCRIPT" --help 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "--help did not exit 0"
  assert_contains "$out" 'Usage:' "--help printed no usage"
  pass "file input, stdin, labels, and usage errors behave"
}

test_clean_body_passes() {
  assert_clean $'## Summary\n\nAdds a lint for outbound text.\n\n## Testing\n\nRun the unit tests.'
  pass "a clean multi-line description passes"
}

test_rule_a_words
test_rule_a_does_not_flag_unrelated_words
test_rule_a_reports_line_numbers
test_rule_p_paths
test_rule_t_tokens
test_commit_message_mode
test_input_modes_and_usage
test_clean_body_passes

echo "# all fm-outward-text-lint tests passed"
