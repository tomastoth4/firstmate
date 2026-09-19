#!/usr/bin/env bash
# Behavior tests for fm_quota_json_valid in bin/fm-quota-axi-lib.sh.
#
# Drives the validator on stdin with schema-5 and schema-6 snapshots. Schema 6
# is the account-expanded shape: every provider carries an accountKey and the
# same provider may repeat under distinct account keys. The validator must
# accept both schemas, key provider uniqueness on (provider, accountKey), and
# reject a schema-6 snapshot that omits accountKey or repeats an identity.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$ROOT/bin/fm-quota-axi-lib.sh"

# valid <json> -> exit status of the validator.
valid() { printf '%s' "$1" | fm_quota_json_valid; }

S5='{ "schemaVersion": 5, "providers": [
  { "provider": "opencode-go", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } },
  { "provider": "claude", "quotaSemantics": { "status": "known", "effectiveAvailability": [
    { "scope": "all_models", "status": "known", "effectivePercentRemaining": 50, "runway": { "status": "through_reset" } } ] } } ] }'
if valid "$S5"; then pass "a schema-5 snapshot is accepted"; else fail "schema 5 must stay valid"; fi

S6='{ "schemaVersion": 6, "providers": [
  { "provider": "opencode-go", "accountKey": "default", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } },
  { "provider": "claude", "accountKey": "default", "quotaSemantics": { "status": "known", "effectiveAvailability": [
    { "scope": "all_models", "status": "known", "effectivePercentRemaining": 50, "runway": { "status": "through_reset" } } ] } } ] }'
if valid "$S6"; then pass "a schema-6 account-expanded snapshot is accepted"; else fail "schema 6 must be valid"; fi

S6_MULTI='{ "schemaVersion": 6, "providers": [
  { "provider": "opencode-go", "accountKey": "default", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } },
  { "provider": "opencode-go", "accountKey": "work", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } } ] }'
if valid "$S6_MULTI"; then pass "the same provider under two account keys is accepted"; else fail "distinct account keys must be valid"; fi

S6_NO_KEY='{ "schemaVersion": 6, "providers": [
  { "provider": "claude", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } } ] }'
if valid "$S6_NO_KEY"; then fail "schema 6 without accountKey must be rejected"; else pass "a schema-6 provider missing accountKey is rejected"; fi

S6_DUP='{ "schemaVersion": 6, "providers": [
  { "provider": "opencode-go", "accountKey": "default", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } },
  { "provider": "opencode-go", "accountKey": "default", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } } ] }'
if valid "$S6_DUP"; then fail "a duplicate (provider, accountKey) must be rejected"; else pass "a duplicate provider account identity is rejected"; fi

S5_DUP='{ "schemaVersion": 5, "providers": [
  { "provider": "claude", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } },
  { "provider": "claude", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } } ] }'
if valid "$S5_DUP"; then fail "a duplicate schema-5 provider must be rejected"; else pass "a duplicate schema-5 provider is rejected"; fi

S7='{ "schemaVersion": 7, "providers": [
  { "provider": "claude", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } } ] }'
if valid "$S7"; then fail "an unsupported schema version must be rejected"; else pass "an unknown schema version is rejected"; fi

printf '# all fm-quota-axi-lib tests passed\n'
