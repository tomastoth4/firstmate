# shellcheck shell=bash
# fm-quota-opencode-lib.sh - derive a comparable spendPriority for the
# opencode-go provider so quota-informed dispatch can rank it.
# Usage: . bin/fm-quota-opencode-lib.sh
#
# WHY THIS EXISTS. quota-axi reports opencode-go headroom (rolling, weekly,
# monthly percentRemaining plus resetsAt) but cannot resolve each window's cycle
# length: OpenCode publishes the caps, not the exact window durations, and the
# API does not expose them. With no cycle, quota-axi leaves the scope's
# selection scalar "unknown" (no spendPriority), so bin/fm-dispatch-resolve.sh
# treats opencode-go as not rankable and escalates instead of choosing it.
#
# WHAT IT DOES. It supplies only the one missing input - each window's cycle
# length - and then computes the SAME selection scalar quota-axi computes for a
# provider that has a cycle, so the resulting spendPriority is on the identical
# scale and meaning as claude or codex, never a made-up number. The formula is a
# faithful copy of quota-axi's pace.js: for each bounding window,
#   timeRemainingPercent t = 100 * (resetsAt - generatedAt) / cycleSeconds
#   burnMultiple b        = (100 - percentRemaining) / (100 - t)
#   gap                   = percentRemaining / t - b
# and the scope scalar is the cycle-seconds-weighted mean of the window gaps,
# clamped to [-100, 100] and rounded to four decimals. Reproducing claude's
# emitted spendPriority from its resetsAt cadence and known cycle lengths is the
# oracle the colocated test pins.
#
# CYCLE DERIVATION, SELF-CORRECTING. A single snapshot only gives time-remaining,
# so this records each observed (observed_at, resetsAt) pair per window in a
# home-local, gitignored record and derives the cycle from the cadence over
# time. Seeds start sensible and are refined by observation:
#   rolling  ~5h  (18000s)   - a rolling session window.
#   weekly   ~7d  (604800s)  - resetsAt lands on midnight, so a calendar week.
#   monthly  ~30d (2592000s) - resetsAt is NOT a calendar boundary (e.g. an
#                              Oct-17 07:29 reset), so a ~30-day rolling window.
# Refinement uses reset JUMPS first (a forward jump in resetsAt between samples
# is one cycle length; the median of in-band jumps wins), and otherwise widens
# the seed to the largest observed time-to-reset, which can never exceed one
# cycle. The estimate therefore self-corrects from real cadence and never
# depends on the hardcoded seed once jumps are observed.
#
# BEST EFFORT, NEVER BLOCKING. Every failure - unreadable record, unwritable
# state dir, malformed snapshot, missing jq - passes the input snapshot through
# unchanged, because enrichment must never change whether dispatch resolves.
# It only fills a row whose headroom is known but whose spendPriority is missing;
# it never overwrites a selection quota-axi already resolved.

FM_QUOTA_OPENCODE_PROVIDER=opencode-go
FM_QUOTA_OPENCODE_SEED_ROLLING=18000
FM_QUOTA_OPENCODE_SEED_WEEKLY=604800
FM_QUOTA_OPENCODE_SEED_MONTHLY=2592000
FM_QUOTA_OPENCODE_MAX_SAMPLES=64

# Path of the home-local cadence record. FM_HOME selects the home; state/ is
# gitignored, so the record is captain-private and never committed.
fm_quota_opencode_cadence_path() {
  printf '%s/state/quota-opencode-cadence.json\n' "${FM_HOME:-.}"
}

# The jq helpers every stage shares: portable ISO->epoch seconds and the
# quota-axi selection formula. Emitted as one string so each jq call embeds it.
fm_quota_opencode_jq_helpers() {
  cat <<'JQ'
def iso2epoch:
  (. // "") | if type != "string" then null
  else (sub("\\.[0-9]+"; "") | sub("(\\+00:?00|Z)$"; "Z"))
    | (try fromdateiso8601 catch null)
  end;
def window_gap($g):
  .cycleSeconds as $C
  | .percentRemaining as $r
  | .resetsAtEpoch as $R
  | if ($C == null) or ($r == null) or ($R == null) or ($g == null) then null
    elif ($C <= 0) then null
    else ($R - $g) as $remSec
    | if $remSec <= 0 then null
      else ((100 * $remSec) / $C) as $t
      | if $t > 100 then null
        elif $t < 0.01 then null
        else (100 - $t) as $e
        | (100 - $r) as $u
        | (if $e > 0 then ($u / $e) elif $u == 0 then 0 else null end) as $b
        | if $b == null then null else (($r / $t) - $b) end
        end
      end
    end;
def spend_priority($g; $windows):
  [$windows[] | {C: .cycleSeconds, gap: window_gap($g)}] as $terms
  | if ($terms | length) == 0 then null
    elif any($terms[]; (.gap == null) or (.C == null) or (.C <= 0)) then null
    else ([$terms[] | .gap * .C] | add) as $num
    | ([$terms[] | .C] | add) as $den
    | if ($den == 0) then null
      else (($num / $den) as $m
        | ([([-100, $m] | max), 100] | min)
        | (. * 10000 | round) / 10000)
      end
    end;
JQ
}

# Read the opencode-go provider's windows from a snapshot on stdin and merge one
# (observed_at, resetsAt) sample per window into the record, dedup by
# (id, resetsAt) and bounded to the most recent FM_QUOTA_OPENCODE_MAX_SAMPLES.
# Writes the record atomically; a failure is swallowed so enrichment continues
# on seeds.
fm_quota_opencode_record_samples() {
  local snapshot=$1 record tmp dir
  record=$(fm_quota_opencode_cadence_path)
  dir=$(dirname "$record")
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  local existing='{"provider":"opencode-go","windows":{}}'
  if [ -f "$record" ]; then
    existing=$(cat "$record" 2>/dev/null) || existing='{"provider":"opencode-go","windows":{}}'
    printf '%s' "$existing" | jq -e . >/dev/null 2>&1 || existing='{"provider":"opencode-go","windows":{}}'
  fi
  tmp=$(mktemp "$dir/.quota-opencode-cadence.XXXXXX" 2>/dev/null) || return 0
  if printf '%s' "$snapshot" | jq \
      --argjson prior "$existing" \
      --arg provider "$FM_QUOTA_OPENCODE_PROVIDER" \
      --argjson cap "$FM_QUOTA_OPENCODE_MAX_SAMPLES" '
      ([.providers[]? | select(.provider == $provider)] | first) as $p
      | (.generatedAt // $p.generatedAt) as $observed
      | ($prior.windows // {}) as $w
      | if $p == null or $observed == null then $prior
        else
          reduce ($p.windows[]? | select((.id | type) == "string" and (.resetsAt | type) == "string")) as $win
            ($prior;
              .windows[$win.id] = {samples: (
                (($w[$win.id].samples // []) + [{observed_at: $observed, resetsAt: $win.resetsAt}])
                | unique_by(.resetsAt)
                | sort_by(.observed_at)
                | .[-($cap):]
              )})
          | .provider = $provider
        end
    ' > "$tmp" 2>/dev/null
  then
    mv "$tmp" "$record" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# Derive cycleSeconds per window id from the record, emitting a JSON object
# {id: cycleSeconds}. Reset jumps in band win; else the seed widened to the
# largest observed time-to-reset.
fm_quota_opencode_derive_cycles() {
  local record seeds
  record=$(fm_quota_opencode_cadence_path)
  local doc='{"windows":{}}'
  if [ -f "$record" ]; then
    doc=$(cat "$record" 2>/dev/null) || doc='{"windows":{}}'
    printf '%s' "$doc" | jq -e . >/dev/null 2>&1 || doc='{"windows":{}}'
  fi
  seeds=$(printf '{"rolling":%s,"weekly":%s,"monthly":%s}' \
    "$FM_QUOTA_OPENCODE_SEED_ROLLING" "$FM_QUOTA_OPENCODE_SEED_WEEKLY" "$FM_QUOTA_OPENCODE_SEED_MONTHLY")
  printf '%s' "$doc" | jq -c --argjson seeds "$seeds" "
    $(fm_quota_opencode_jq_helpers)
    def median(\$xs):
      (\$xs | sort) as \$s | (\$s | length) as \$n
      | if \$n == 0 then null
        elif (\$n % 2) == 1 then \$s[(\$n - 1) / 2]
        else ((\$s[(\$n / 2) - 1] + \$s[\$n / 2]) / 2) end;
    def seed_for(\$id):
      (\$seeds[\$id]) // (if (\$id | test(\"week\")) then \$seeds.weekly
        elif (\$id | test(\"month\")) then \$seeds.monthly
        else \$seeds.rolling end);
    (.windows // {}) as \$w
    | reduce (\$w | keys_unsorted[]) as \$id ({};
        (seed_for(\$id)) as \$seed
        | ([\$w[\$id].samples[]? | {o: (.observed_at | iso2epoch), r: (.resetsAt | iso2epoch)}
             | select(.o != null and .r != null)]) as \$samples
        | ([\$samples[].r] | unique | sort) as \$resets
        | ([range(0; (\$resets | length) - 1) as \$i | (\$resets[\$i + 1] - \$resets[\$i])
             | select(. >= (\$seed * 0.25) and . <= (\$seed * 4))]) as \$jumps
        | ([\$samples[] | (.r - .o) | select(. > 0)] | max) as \$maxRemain
        | (if (\$jumps | length) > 0 then median(\$jumps)
           elif \$maxRemain != null and \$maxRemain > \$seed then \$maxRemain
           else \$seed end) as \$cycle
        | . + {(\$id): \$cycle})
  " 2>/dev/null || printf '%s\n' "$seeds"
}

# fm_quota_opencode_enrich: snapshot JSON on stdin -> enriched snapshot on
# stdout. Records the cadence sample, derives cycles, and fills the spendPriority
# of every opencode-go availability row whose headroom is known but whose
# selection quota-axi left unresolved. Any failure echoes the input unchanged.
fm_quota_opencode_enrich() {
  local snapshot cycles out
  snapshot=$(cat)
  command -v jq >/dev/null 2>&1 || { printf '%s' "$snapshot"; return 0; }
  printf '%s' "$snapshot" | jq -e . >/dev/null 2>&1 || { printf '%s' "$snapshot"; return 0; }
  # Nothing to do unless opencode-go carries an availability row that is
  # measured (known headroom) yet has no numeric spendPriority.
  if ! printf '%s' "$snapshot" | jq -e --arg provider "$FM_QUOTA_OPENCODE_PROVIDER" '
      [.providers[]? | select(.provider == $provider)
        | .quotaSemantics.effectiveAvailability[]?
        | select(.status == "known" and ((.selection.spendPriority | type) != "number"))] | length > 0
    ' >/dev/null 2>&1; then
    printf '%s' "$snapshot"; return 0
  fi
  fm_quota_opencode_record_samples "$snapshot"
  cycles=$(fm_quota_opencode_derive_cycles)
  printf '%s' "$cycles" | jq -e . >/dev/null 2>&1 || { printf '%s' "$snapshot"; return 0; }
  out=$(printf '%s' "$snapshot" | jq -c --argjson cycles "$cycles" --arg provider "$FM_QUOTA_OPENCODE_PROVIDER" "
    $(fm_quota_opencode_jq_helpers)
    def cycle_for(\$id): \$cycles[\$id];
    (.generatedAt | iso2epoch) as \$g
    | .providers |= map(
        if .provider != \$provider then .
        else . as \$prov
          | (\$prov.windows // []) as \$wins
          | .quotaSemantics.effectiveAvailability = (
              (.quotaSemantics.effectiveAvailability // []) | map(
                . as \$row
                | if (\$row.status == \"known\") and ((\$row.selection.spendPriority | type) != \"number\")
                  then
                    (if (\$row.boundedBy | type) == \"array\" and (\$row.boundedBy | length) > 0
                       then \$row.boundedBy
                       else [\$wins[] | select(.kind != \"model\") | .id] end) as \$ids
                    | ([\$ids[] as \$id | (\$wins[] | select(.id == \$id)) as \$win
                         | {cycleSeconds: cycle_for(\$id),
                            percentRemaining: \$win.percentRemaining,
                            resetsAtEpoch: (\$win.resetsAt | iso2epoch)}]) as \$bw
                    | spend_priority(\$g; \$bw) as \$sp
                    | if \$sp == null then \$row
                      else \$row
                        | .selection = ((.selection // {})
                            + {status: \"known\", spendPriority: \$sp, derivedBy: \"firstmate-opencode-cycle\"}
                            | del(.unmeasurableWindowIds))
                      end
                  else \$row end
              ))
        end)
  " 2>/dev/null) || { printf '%s' "$snapshot"; return 0; }
  [ -n "$out" ] || { printf '%s' "$snapshot"; return 0; }
  printf '%s' "$out"
}
