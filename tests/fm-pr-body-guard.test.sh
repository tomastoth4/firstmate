#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-body-guard.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-body-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-body-guard)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

# The fake gh serves the fixture files each case exports: the PR body, the
# comment bodies, and the repository's PR template (encoded to base64 exactly
# as the contents API returns it, including line wrapping). It serves raw
# values, the way plain `gh api --jq` does; a separate fixture drives the
# found-but-undecodable template error. A contents call for any other
# candidate path exits 1 quietly, the way a 404 does.
# A fake gh-axi also sits on the PATH and always exits 91: the guard must
# fetch through gh, so a regression back to the gh-axi TOON envelope (which
# wraps API output and once broke the template base64 decode) fails loudly.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" repos/o/r/pulls/7 --jq .body "*)
    cat "${FM_PRG_BODY:?}" 2>/dev/null || exit 1
    ;;
  *" repos/o/r/issues/7/comments "*)
    if [ -n "${FM_PRG_COMMENTS:-}" ]; then cat "$FM_PRG_COMMENTS"; fi
    ;;
  *" repos/o/r/contents/.github/pull_request_template.md --jq .content "*)
    if [ -n "${FM_PRG_TEMPLATE:-}" ]; then
      base64 "$FM_PRG_TEMPLATE"
    elif [ -n "${FM_PRG_TEMPLATE_DECODE_FAIL:-}" ]; then
      cat "$FM_PRG_TEMPLATE_DECODE_FAIL"
    else
      exit 1
    fi
    ;;
  *" repos/o/r/contents/"*)
    exit 1
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 91
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'the guard must fetch through plain gh, not gh-axi: %s\n' "$*" >&2
exit 91
SH
chmod +x "$FAKEBIN/gh-axi"

run_guard() {
  PATH="$FAKEBIN:$PATH" "$SCRIPT" o r 7
}

test_grep_fallback_without_rg() {
  # CI runners ship no ripgrep, so the guard must work on grep alone. Build a
  # PATH that has every tool the guard needs except rg and run a forbidden
  # vocabulary refusal through it.
  local norg out rc tool
  norg="$TMP_ROOT/no-rg-bin"
  mkdir -p "$norg"
  for tool in bash grep base64 mktemp rm cp tr cat; do
    ln -s "$(command -v "$tool")" "$norg/$tool"
  done
  local body
  body=$(write_fixture body-norg.md 'apply the CAPTAIN decision')
  out=$(PATH="$norg:$FAKEBIN" FM_PRG_BODY=$body "$SCRIPT" o r 7 2>&1) && rc=0 || rc=$?
  assert_refused 'RULE A' "the grep fallback without rg" "$out" "$rc"
  pass "the guard works without rg on PATH (grep fallback)"
}

assert_refused() { # <expected-rule> <label>: last captured run must fail naming the rule
  local rule=$1 label=$2 out=$3 rc=$4
  [ "$rc" -ne 0 ] || fail "$label: guard accepted a violating description"
  assert_contains "$out" "$rule" "$label: refusal did not name the rule"
}

TEMPLATE_FILE="$TMP_ROOT/template.md"
printf '%s\n' \
  '## Summary' \
  '' \
  'Please include a summary.' \
  '' \
  '```' \
  '## Fenced Placeholder' \
  '```' \
  '' \
  '## Testing' \
  '' \
  'Describe testing.' > "$TEMPLATE_FILE"

write_fixture() { # <name> <content...>: write a fixture file under the temp root
  local file="$TMP_ROOT/$1"
  shift
  printf '%s\n' "$@" > "$file"
  printf '%s\n' "$file"
}

test_clean_template_match_passes() {
  local body out rc
  body=$(write_fixture body-clean.md '## Summary' '' 'Does the thing.' '' '## Testing' '' 'Unit tests.')
  out=$(FM_PRG_BODY=$body FM_PRG_TEMPLATE=$TEMPLATE_FILE run_guard 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a description matching the template exactly was refused: $out"
  assert_contains "$out" 'ok:' "a passing guard did not print its OK line"
  pass "a description matching the template exactly passes"
}

test_forbidden_vocabulary_refused() {
  local body out rc
  body=$(write_fixture body-vocab.md '## Summary' '' 'Apply the CAPTAIN decision for review findings.' \
    'Thanks to the Firstmate crew.' '' '## Testing' '' 'run the suite')
  out=$(FM_PRG_BODY=$body FM_PRG_TEMPLATE=$TEMPLATE_FILE run_guard 2>&1) && rc=0 || rc=$?
  assert_refused 'RULE A' "forbidden vocabulary in a description" "$out" "$rc"
  assert_contains "$out" 'CAPTAIN' "the guard did not print the offending line"
  pass "forbidden vocabulary in a description is refused with the offending line"
}

test_forbidden_vocabulary_without_template_refused() {
  local body out rc
  body=$(write_fixture body-vocab-notemplate.md 'first mate report')
  out=$(FM_PRG_BODY=$body run_guard 2>&1) && rc=0 || rc=$?
  assert_refused 'RULE A' "forbidden vocabulary without a template" "$out" "$rc"
  pass "forbidden vocabulary is refused even when the repository has no template"
}

test_template_decode_failure_refused() {
  # A template found through the contents API whose base64 does not decode
  # cannot mean no template: it means the fetched text is not the raw
  # contents value (the gh-axi TOON envelope once caused exactly this). The
  # guard must stop hard instead of silently skipping template adherence.
  local body out rc envelope
  body=$(write_fixture body-decodefail.md 'plain description')
  envelope=$(write_fixture envelope.txt 'api_response:' '  body: "c29tZXRoaW5nIHRoYXQgaXMgbm90IGJhc2U2NCAtLQ=="')
  out=$(FM_PRG_BODY=$body FM_PRG_TEMPLATE_DECODE_FAIL="$envelope" run_guard 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "an undecodable found template was treated as no template"
  assert_contains "$out" 'could not decode' "the decode-failure refusal did not name the problem"
  pass "a found template that cannot decode is a hard error, never a silent skip"
}

test_template_enforcement_note() {
  # The enforced pass must say so; a guard that silently skips rule B prints
  # the no-template note instead, which is how the wrapped-envelope regression
  # hid: the guard ran, said "no template", and let invented sections through.
  local body out rc
  body=$(write_fixture body-note.md '## Summary' '' 'Does the thing.' '' '## Testing' '' 'Unit tests.')
  out=$(FM_PRG_BODY=$body FM_PRG_TEMPLATE=$TEMPLATE_FILE run_guard 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a template-exact description was refused: $out"
  assert_contains "$out" 'template adherence enforced' "the enforced-template pass did not name the template"
  pass "an enforced template pass names the template, not the no-template note"
}

test_local_clone_template_used() {
  # The contents API can be unreadable while a local clone is exported; the
  # conventional local-clone fallback must still fetch and enforce the
  # template.
  local clone body out rc
  clone=$(mktemp -d "$TMP_ROOT/clone.XXXXXX")
  mkdir -p "$clone/.github"
  cp "$TEMPLATE_FILE" "$clone/.github/pull_request_template.md"
  body=$(write_fixture body-clonetmpl.md '## Summary' '' 'Does the thing.' '' '## Testing' '' 'Unit tests.')
  out=$(FM_PRG_BODY=$body FM_PR_BODY_GUARD_LOCAL_CLONE=$clone run_guard 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a template reachable only through the local clone was not enforced: $out"
  assert_contains "$out" 'template adherence enforced' "the local-clone pass did not name the template"
  pass "a template in the exported local clone is found and enforced"
}

test_missing_required_heading_refused() {
  local body out rc
  body=$(write_fixture body-missing.md '## Summary' '' 'Does the thing.')
  out=$(FM_PRG_BODY=$body FM_PRG_TEMPLATE=$TEMPLATE_FILE run_guard 2>&1) && rc=0 || rc=$?
  assert_refused 'RULE B' "a description missing a required heading" "$out" "$rc"
  assert_contains "$out" 'Testing' "the refusal did not name the missing heading"
  pass "a description missing a required template heading is refused"
}

test_invented_extra_section_refused() {
  local body out rc
  body=$(write_fixture body-extra.md '## Summary' '' 'Does the thing.' '' '## Testing' '' 'Unit tests.' \
    '' '## Risk Assessment' '' 'low')
  out=$(FM_PRG_BODY=$body FM_PRG_TEMPLATE=$TEMPLATE_FILE run_guard 2>&1) && rc=0 || rc=$?
  assert_refused 'RULE B' "an invented extra section" "$out" "$rc"
  assert_contains "$out" 'Risk Assessment' "the refusal did not name the unexpected heading"
  pass "an invented extra section is refused"
}

test_reordered_sections_refused() {
  local body out rc
  body=$(write_fixture body-reordered.md '## Testing' '' 'Unit tests.' '' '## Summary' '' 'Does the thing.')
  out=$(FM_PRG_BODY=$body FM_PRG_TEMPLATE=$TEMPLATE_FILE run_guard 2>&1) && rc=0 || rc=$?
  assert_refused 'RULE B' "sections out of template order" "$out" "$rc"
  assert_contains "$out" 'order' "the reorder refusal did not explain the order problem"
  pass "sections in the wrong order are refused"
}

test_fenced_placeholder_heading_ignored() {
  local body out rc
  body=$(write_fixture body-fenced.md '## Summary' '' 'Does the thing.' '' '## Testing' '' 'Unit tests.' \
    '' '```' '## Not A Section' '```')
  out=$(FM_PRG_BODY=$body FM_PRG_TEMPLATE=$TEMPLATE_FILE run_guard 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a fenced heading in the description was treated as a section: $out"
  pass "a heading inside a fenced block in the description is not a section"
}

test_pipeline_section_refused() {
  local body out rc
  body=$(write_fixture body-pipeline.md '## Summary' '' 'Does the thing.' '' '## Pipeline' '' '- review: pass')
  out=$(FM_PRG_BODY=$body run_guard 2>&1) && rc=0 || rc=$?
  assert_refused 'RULE C' "a Pipeline section in a description" "$out" "$rc"
  pass "a Pipeline section in a description is refused"
}

test_attestation_marker_in_body_refused() {
  local body out rc
  body=$(write_fixture body-attest.md '## Summary' '' 'Does the thing.' \
    '<!-- no-mistakes-pipeline-attestation:v1 sha256=abc -->')
  out=$(FM_PRG_BODY=$body run_guard 2>&1) && rc=0 || rc=$?
  assert_refused 'RULE C' "an attestation marker in a description" "$out" "$rc"
  pass "an attestation marker in a description is refused"
}

test_appendix_marker_in_body_refused() {
  local body out rc
  body=$(write_fixture body-appendix.md '## Summary' '' 'Does the thing.' \
    '<!-- no-mistakes-pr-appendix:v1 sha256=abc -->')
  out=$(FM_PRG_BODY=$body run_guard 2>&1) && rc=0 || rc=$?
  assert_refused 'RULE C' "an appendix marker in a description" "$out" "$rc"
  pass "an appendix marker in a description is refused"
}

test_pipeline_content_in_comment_refused() {
  local body comments out rc
  body=$(write_fixture body-comment-clean.md 'plain description')
  comments=$(write_fixture comments-pipeline.md \
    'looks good to me' '<!-- no-mistakes-pipeline-attestation:v1 sha256=abc -->')
  out=$(FM_PRG_BODY=$body FM_PRG_COMMENTS=$comments run_guard 2>&1) && rc=0 || rc=$?
  assert_refused 'RULE C' "pipeline content in a comment" "$out" "$rc"
  pass "pipeline tooling content in a comment is refused"
}

test_clean_comment_passes() {
  local body comments out rc
  body=$(write_fixture body-notemplate-clean.md 'plain description')
  comments=$(write_fixture comments-clean.md 'nice work')
  out=$(FM_PRG_BODY=$body FM_PRG_COMMENTS=$comments run_guard 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a clean description with clean comments was refused: $out"
  assert_contains "$out" 'no PR template' "a template-less repository did not print the skip note"
  pass "with no template, a clean description and comments pass with a note"
}

test_usage_refusals() {
  local out rc
  out=$(run_guard o r 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "missing pr-number was accepted"
  out=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" o r not-a-number 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-numeric pr-number was accepted"
  pass "usage refusals exit nonzero"
}

test_grep_fallback_without_rg
test_clean_template_match_passes
test_template_enforcement_note
test_local_clone_template_used
test_forbidden_vocabulary_refused
test_forbidden_vocabulary_without_template_refused
test_template_decode_failure_refused
test_missing_required_heading_refused
test_invented_extra_section_refused
test_reordered_sections_refused
test_fenced_placeholder_heading_ignored
test_pipeline_section_refused
test_attestation_marker_in_body_refused
test_appendix_marker_in_body_refused
test_pipeline_content_in_comment_refused
test_clean_comment_passes
test_usage_refusals
