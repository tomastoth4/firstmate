#!/usr/bin/env bash
set -u

RULE_A_PATTERN='(^|[^[:alnum:]])(captains?|firstmates?|first[[:space:]_-]+mates?)([^[:alnum:]]|$)'
RULE_P_PATTERN='(/home/[A-Za-z0-9._-]+/|/Users/[A-Za-z0-9._-]+/|~/\.treehouse|/\.treehouse/|/firstmate[A-Za-z0-9._-]*/(state|data)/)'
RULE_T_PATTERN='[?&#;](orderlinktoken|order[_-]link[_-]token|access[_-]?token|api[_-]?key|token|secret|password)=[A-Za-z0-9._~%+/-]{8,}'

usage() {
  cat <<'EOF'
Usage: fm-outward-text-lint.sh [--commit-msg] [--label <name>] [<file>|-]

Lints text that leaves the machine: a commit message, a PR or issue title or
description, a PR comment, or a review reply. Reads <file>, or stdin when no
file or "-" is given.

Rules:
  A  the words captain, firstmate, and first mate (case-insensitive, whole words)
  P  private machine paths: /home/<name>/, /Users/<name>/, ~/.treehouse,
     /.treehouse/, and absolute firstmate state/ or data/ paths
  T  secret tokens in a URL query or fragment, such as orderLinkToken=<value>

--commit-msg drops git comment lines and everything after the scissors line
before linting. --label names the artifact in the diagnostic.

Exit 0 when the text is clean. Exit 1 when a rule matches, printing the rule,
the offending line numbers, and a one-line fix hint on stderr. Exit 2 on usage
errors.
EOF
}

COMMIT_MSG=0
LABEL=text
INPUT=-

while [ "$#" -gt 0 ]; do
  case "$1" in
    --commit-msg)
      COMMIT_MSG=1
      shift
      ;;
    --label)
      [ "$#" -gt 1 ] || { echo "error: --label requires a value" >&2; exit 2; }
      LABEL=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -)
      INPUT=-
      shift
      ;;
    -*)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      INPUT=$1
      shift
      ;;
  esac
done

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-outward-text-lint.XXXXXX") || exit 2
trap 'rm -rf "$TMP_DIR"' EXIT
trap 'exit 2' HUP INT TERM
TEXT_FILE="$TMP_DIR/text"

if [ "$INPUT" = "-" ]; then
  cat > "$TEXT_FILE" || exit 2
else
  [ -f "$INPUT" ] && [ -r "$INPUT" ] || { echo "error: cannot read $INPUT" >&2; exit 2; }
  cp "$INPUT" "$TEXT_FILE" || exit 2
fi

if [ "$COMMIT_MSG" -eq 1 ]; then
  sed -e '/^# -* >8 -*$/,$d' -e 's/^#.*//' "$TEXT_FILE" > "$TMP_DIR/message" || exit 2
  mv "$TMP_DIR/message" "$TEXT_FILE"
fi

STATUS=0

report() { # <rule> <description> <pattern> <hint> <show-text: 1|0>
  local hits
  hits=$(grep -inE -e "$3" "$TEXT_FILE" || true)
  [ -n "$hits" ] || return 0
  STATUS=1
  printf 'fm-outward-text-lint: RULE %s (%s) in %s:\n' "$1" "$2" "$LABEL" >&2
  if [ "$5" -eq 1 ]; then
    printf '%s\n' "$hits" | sed 's/^\([0-9][0-9]*\):/  line \1: /' >&2
  else
    printf '%s\n' "$hits" | sed 's/^\([0-9][0-9]*\):.*/  line \1: [text withheld]/' >&2
  fi
  printf 'fix: %s\n' "$4" >&2
}

report A 'forbidden vocabulary' "$RULE_A_PATTERN" \
  'remove the words captain, firstmate, and first mate; state the outcome in neutral terms' 1
report P 'private machine path' "$RULE_P_PATTERN" \
  'replace the machine path with a repository-relative path or a placeholder such as <home>' 1
report T 'secret token in a URL' "$RULE_T_PATTERN" \
  'remove the token value from the URL query or fragment' 0

exit "$STATUS"
