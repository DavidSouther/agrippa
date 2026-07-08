#!/usr/bin/env bats
#
# Prober for scripts/rotate-keys.sh's Stage 5: does the SOPS_AGE_KEY handoff
# from an archived Bitwarden item actually let `sops updatekeys` re-encrypt an
# already-committed secret under the new recipient, and drop old-key access?
#
# Bitwarden itself is stubbed (a fake `bw` on PATH backed by a JSON file) since
# CI/dev machines have no throwaway vault to rotate against; sops, age, and yq
# are real, so the crypto this script actually depends on is genuinely
# exercised, not merely asserted.
#
# Run:  bats tests/rotate-keys.bats
#
# Requires: bats-core, sops, age (age-keygen), jq, yq -- all pinned by
# mise.toml (`mise exec -- bats tests/rotate-keys.bats` if they aren't
# already on PATH).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  ROTATE_KEYS="$REPO_ROOT/scripts/rotate-keys.sh"

  # Fake `bw` on PATH ahead of anything real, backed by a JSON "vault" file: a
  # JSON array of {id, name, notes}. Speaks just enough of the real bw CLI's
  # I/O shape for scripts/rotate-keys.sh and scripts/lib/bw-status.sh.
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export FAKE_BW_VAULT="$BATS_TEST_TMPDIR/vault.json"
  cat > "$STUB_BIN/bw" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
VAULT="${FAKE_BW_VAULT:?FAKE_BW_VAULT must be set}"
cmd="${1:-}"
sub="${2:-}"
case "$cmd" in
  status) echo '{"status":"unlocked"}' ;;
  encode) cat ;;
  list) cat "$VAULT" ;;
  get)
    case "$sub" in
      template) echo '{"type":2,"name":"","secureNote":{"type":0},"notes":""}' ;;
      item)
        id="${3:-}"
        jq --arg id "$id" '.[] | select(.id == $id)' "$VAULT"
        ;;
      notes)
        id="${3:-}"
        jq -r --arg id "$id" '.[] | select(.id == $id) | .notes' "$VAULT"
        ;;
      *) echo "fake bw: unhandled 'get $sub'" >&2; exit 1 ;;
    esac
    ;;
  create)
    new="$(cat)"
    id="fake-$RANDOM-$$"
    tmp="$(mktemp)"
    jq --argjson item "$new" --arg id "$id" '. + [$item + {id: $id}]' "$VAULT" > "$tmp"
    mv "$tmp" "$VAULT"
    ;;
  edit)
    id="${3:-}"
    new="$(cat)"
    tmp="$(mktemp)"
    jq --argjson item "$new" --arg id "$id" \
      'map(if .id == $id then ($item + {id: $id}) else . end)' "$VAULT" > "$tmp"
    mv "$tmp" "$VAULT"
    ;;
  *) echo "fake bw: unhandled invocation: $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$STUB_BIN/bw"
  export PATH="$STUB_BIN:$PATH"
}

@test "rotate-keys archives (not deletes) the old Bitwarden item and re-encrypts an already-committed secret to the new recipient" {
  cd "$BATS_TEST_TMPDIR"
  ENV_NAME="citest"

  # GIVEN: an existing Bitwarden item for this env holding an OLD age identity,
  # a .sops.yaml scoping secrets/citest/.* to its recipient, and a secret
  # already committed and encrypted under that OLD recipient.
  identity_old="$(age-keygen 2>/dev/null)"
  jq -n --arg id "old-1" --arg name "agrippa-age-${ENV_NAME}" --arg notes "$identity_old" \
    '[{id: $id, name: $name, notes: $notes}]' > "$FAKE_BW_VAULT"

  recipient_old="$(printf '%s\n' "$identity_old" | grep '^# public key: ' | sed -E 's/^# public key: //')"
  printf 'creation_rules:\n  - path_regex: ^secrets/%s/.*$\n    age: %s\n' \
    "$ENV_NAME" "$recipient_old" > .sops.yaml

  mkdir -p "secrets/${ENV_NAME}"
  cat > "secrets/${ENV_NAME}/example.enc.yaml" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: example
stringData:
  password: hunter2
EOF
  run sops --config .sops.yaml -e -i "secrets/${ENV_NAME}/example.enc.yaml"
  [ "$status" -eq 0 ]

  # WHEN: rotate-keys runs against this env, confirming the interactive prompt.
  run bash -c "printf 'rotate\n' | '$ROTATE_KEYS' '$ENV_NAME'"
  [ "$status" -eq 0 ]

  # THEN 1: the old item is archived under a distinct, dated name -- not
  # deleted -- so its identity is still recoverable in the vault.
  archived_name="$(jq -r --arg id "old-1" '.[] | select(.id == $id) | .name' "$FAKE_BW_VAULT")"
  echo "$archived_name" | grep -qE "^agrippa-age-${ENV_NAME} \(archived [0-9]{4}-[0-9]{2}-[0-9]{2}\)\$"
  archived_notes="$(jq -r --arg id "old-1" '.[] | select(.id == $id) | .notes' "$FAKE_BW_VAULT")"
  [ "$archived_notes" = "$identity_old" ]

  # THEN 2: a new, live item now holds a different identity under the
  # original name.
  new_notes="$(jq -r --arg name "agrippa-age-${ENV_NAME}" '.[] | select(.name == $name) | .notes' "$FAKE_BW_VAULT")"
  [ -n "$new_notes" ]
  [ "$new_notes" != "$identity_old" ]

  # THEN 3: .sops.yaml's recipient for this env now matches the new identity.
  export CHECK_PATH_REGEX="^secrets/${ENV_NAME}/.*\$"
  sops_yaml_age="$(yq '.creation_rules[] | select(.path_regex == env(CHECK_PATH_REGEX)) | .age' .sops.yaml)"
  unset CHECK_PATH_REGEX
  recipient_new="$(printf '%s\n' "$new_notes" | grep '^# public key: ' | sed -E 's/^# public key: //')"
  [ "$sops_yaml_age" = "$recipient_new" ]

  # THEN 4: the already-committed secret now decrypts under the NEW key...
  run env SOPS_AGE_KEY="$new_notes" sops -d "secrets/${ENV_NAME}/example.enc.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "hunter2"

  # ...and no longer under the OLD key -- rotation actually dropped old
  # access, it didn't just add the new key alongside it.
  run env SOPS_AGE_KEY="$identity_old" sops -d "secrets/${ENV_NAME}/example.enc.yaml"
  [ "$status" -ne 0 ]
}
