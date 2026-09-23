#!/usr/bin/env bash
# Deterministic content guard for a GitHub pull request's outward-facing text.
# bin/fm-pr-check.sh runs this after it resolves the PR's owner, repo, and
# number and before it records pr= or arms the merge poll, so a violating PR is
# never registered or watched.
# Rules:
#   A  forbidden vocabulary: the description never contains "captain",
#      "firstmate", or "first mate" (case-insensitive).
#   B  exact template adherence: when the repository has a PR template, the
#      description must contain every template top-level "## " heading, in the
#      template's order, and no extra top-level "## " heading. There is no
#      accepted addition: a missing heading, a reordering, or an invented
#      section fails with the offending headings named. With no template
#      found, B passes with a printed note while A and C still apply.
#   C  no pipeline tooling content: no "## Pipeline" section, no
#      no-mistakes-pipeline-attestation marker, and no no-mistakes-pr-appendix
#      marker in the description, and no comment carrying the same markers.
# Consistency with the no-mistakes pipeline: a pipeline run writes its own
# attestation, "## Pipeline" section, and sha256-owned pr-appendix block into
# the PR body, and no no-mistakes setting disables that write, so a
# pipeline-owned PR passes this guard only after its worker strips every
# no-mistakes content block from the description and deletes any no-mistakes
# PR comments as the final step before reporting the PR ready.
# Exit 0 only when every applicable rule passes, printing one OK line; any
# rule failure prints its diagnostic on stderr and exits 1.
# Usage: fm-pr-body-guard.sh <owner> <repo> <pr-number>
set -eu

if [ "$#" -ne 3 ]; then
  echo "error: usage: fm-pr-body-guard.sh <owner> <repo> <pr-number>" >&2
  exit 2
fi
OWNER=$1
REPO=$2
NUMBER=$3
case "$NUMBER" in
  ''|*[!0-9]*)
    echo "error: pr-number must be a positive integer" >&2
    exit 2
    ;;
esac
command -v gh-axi >/dev/null 2>&1 \
  || { echo "error: fm-pr-body-guard requires gh-axi on PATH" >&2; exit 1; }

# Matching prefers rg and falls back to grep -in, which every runner has; both
# print the same N:text shape the diagnostics relay verbatim.
match_ci_lines() { # <pattern> <file>: print matching lines with line numbers
  if command -v rg >/dev/null 2>&1; then
    rg -in "$1" "$2" || true
  else
    grep -inE "$1" "$2" || true
  fi
}

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-body-guard.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
trap 'exit 1' HUP INT TERM

BODY_FILE="$TMP_DIR/body"
COMMENTS_FILE="$TMP_DIR/comments"
TEMPLATE_FILE="$TMP_DIR/template"

# Rule fetches: the description, every comment body, and the repository's own
# PR template. The template is looked up through the contents API over the
# conventional repository paths, falling back to a local clone when one is
# exported; the first readable hit wins.
if ! gh-axi api "repos/$OWNER/$REPO/pulls/$NUMBER" --jq .body > "$BODY_FILE" 2>/dev/null; then
  echo "error: could not fetch the pull request body for $OWNER/$REPO#$NUMBER" >&2
  exit 1
fi
if [ "$(cat "$BODY_FILE")" = "null" ]; then
  : > "$BODY_FILE"
fi
if ! gh-axi api "repos/$OWNER/$REPO/issues/$NUMBER/comments" --paginate --jq '.[].body' \
  > "$COMMENTS_FILE" 2>/dev/null; then
  echo "error: could not fetch the pull request comments for $OWNER/$REPO#$NUMBER" >&2
  exit 1
fi

# RULE A: forbidden vocabulary in the description. Print every offending line
# so the caller sees exactly what leaked.
RULE_A_HITS=$(match_ci_lines 'captain|firstmate|first mate' "$BODY_FILE")
if [ -n "$RULE_A_HITS" ]; then
  echo "RULE A: forbidden vocabulary leaked into the PR description (captain / firstmate / first mate):" >&2
  printf '%s\n' "$RULE_A_HITS" >&2
  exit 1
fi

# RULE C: no pipeline tooling content in the description or in any comment.
pipeline_tooling_lines() { # <file>: print the marker lines the rule forbids
  match_ci_lines '^## Pipeline' "$1"
  match_ci_lines 'no-mistakes-pipeline-attestation' "$1"
  match_ci_lines 'no-mistakes-pr-appendix' "$1"
}
RULE_C_HITS=$(pipeline_tooling_lines "$BODY_FILE")
if [ -n "$RULE_C_HITS" ]; then
  echo "RULE C: pipeline tooling content leaked into the PR description:" >&2
  printf '%s\n' "$RULE_C_HITS" >&2
  exit 1
fi
RULE_C_COMMENT_HITS=$(pipeline_tooling_lines "$COMMENTS_FILE")
if [ -n "$RULE_C_COMMENT_HITS" ]; then
  echo "RULE C: pipeline tooling content leaked into a PR comment:" >&2
  printf '%s\n' "$RULE_C_COMMENT_HITS" >&2
  exit 1
fi

# RULE B: exact template adherence.
TEMPLATE_CANDIDATES="
.github/pull_request_template.md
.github/PULL_REQUEST_TEMPLATE.md
.github/PULL_REQUEST_TEMPLATE/pull_request_template.md
docs/pull_request_template.md
docs/PULL_REQUEST_TEMPLATE.md
PULL_REQUEST_TEMPLATE.md
pull_request_template.md
"
fetch_template() { # print the matched template path, or return 1 when none
  local candidate content
  for candidate in $TEMPLATE_CANDIDATES; do
    if content=$(gh-axi api "repos/$OWNER/$REPO/contents/$candidate" --jq .content 2>/dev/null) \
      && [ -n "$content" ] && [ "$content" != "null" ]; then
      if printf '%s\n' "$content" | base64 -d 2>/dev/null > "$TEMPLATE_FILE" \
        || printf '%s\n' "$content" | base64 -D 2>/dev/null > "$TEMPLATE_FILE"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  done
  if [ -n "${FM_PR_BODY_GUARD_LOCAL_CLONE:-}" ] && [ -d "$FM_PR_BODY_GUARD_LOCAL_CLONE" ]; then
    for candidate in $TEMPLATE_CANDIDATES; do
      if [ -f "$FM_PR_BODY_GUARD_LOCAL_CLONE/$candidate" ]; then
        cp "$FM_PR_BODY_GUARD_LOCAL_CLONE/$candidate" "$TEMPLATE_FILE"
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi
  return 1
}

# Print the top-level "## " heading texts of <file>, one per line, skipping
# lines inside fenced blocks so fenced placeholder headings never count.
extract_headings() { # <file>
  local fence=0 line heading
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '```'*)
        fence=$((1 - fence))
        continue
        ;;
    esac
    [ "$fence" -eq 0 ] || continue
    case "$line" in
      '## '*) heading=${line#'## '} ;;
      *) continue ;;
    esac
    [ -n "$heading" ] || continue
    while [ "$heading" != "${heading%[[:space:]]}" ]; do
      heading=${heading%?}
    done
    [ -n "$heading" ] || continue
    printf '%s\n' "$heading"
  done < "$1"
}

TEMPLATE_PATH=$(fetch_template) || TEMPLATE_PATH=
if [ -n "$TEMPLATE_PATH" ]; then
  REQUIRED=$(extract_headings "$TEMPLATE_FILE")
  ACTUAL=$(extract_headings "$BODY_FILE")
  MISSING=
  UNEXPECTED=
  while IFS= read -r heading; do
    [ -n "$heading" ] || continue
    if ! printf '%s\n' "$ACTUAL" | grep -Fxq -- "$heading"; then
      MISSING="${MISSING:+$MISSING, }$heading"
    fi
  done <<EOF
$REQUIRED
EOF
  while IFS= read -r heading; do
    [ -n "$heading" ] || continue
    if ! printf '%s\n' "$REQUIRED" | grep -Fxq -- "$heading"; then
      UNEXPECTED="${UNEXPECTED:+$UNEXPECTED, }$heading"
    fi
  done <<EOF
$ACTUAL
EOF
  if [ -n "$MISSING" ] || [ -n "$UNEXPECTED" ]; then
    echo "RULE B: PR description does not follow the repository PR template ($TEMPLATE_PATH)" >&2
    if [ -n "$MISSING" ]; then
      printf 'missing required section headings: %s\n' "$MISSING" >&2
    fi
    if [ -n "$UNEXPECTED" ]; then
      printf 'unexpected extra section headings: %s\n' "$UNEXPECTED" >&2
    fi
    echo "the description must use the template's sections exactly, in the template's order, with no extra sections" >&2
    exit 1
  fi
  if [ "$REQUIRED" != "$ACTUAL" ]; then
    echo "RULE B: PR description sections are out of the repository PR template's order ($TEMPLATE_PATH)" >&2
    printf 'template section order: %s\n' "$(printf '%s' "$REQUIRED" | tr '\n' '|')" >&2
    printf 'description section order: %s\n' "$(printf '%s' "$ACTUAL" | tr '\n' '|')" >&2
    exit 1
  fi
  printf 'note: template adherence enforced against %s\n' "$TEMPLATE_PATH"
else
  printf 'note: no PR template found in %s/%s; template adherence not enforced\n' "$OWNER" "$REPO"
fi

printf 'ok: PR body guard passed for %s/%s#%s\n' "$OWNER" "$REPO" "$NUMBER"
