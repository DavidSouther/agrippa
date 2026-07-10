#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${AGRIPPA_ENV:-dev}"
positional_count=0
for a in "$@"; do
  case "$a" in
    --*)
      echo "rotate-keys: unknown flag '$a' (this task takes only an environment name; replacing an existing key is confirmed interactively, not by a flag)" >&2
      exit 1
      ;;
    *)
      positional_count=$((positional_count + 1))
      if [ "$positional_count" -gt 1 ]; then
        echo "rotate-keys: too many arguments; expected at most one environment name, got an extra '$a'." >&2
        exit 1
      fi
      ENV_NAME="$a"
      ;;
  esac
done
if [ -z "$ENV_NAME" ]; then
  echo "rotate-keys: environment name must not be empty." >&2
  exit 1
fi
case "$ENV_NAME" in
  *[!a-zA-Z0-9_-]*)
    echo "rotate-keys: environment name '$ENV_NAME' looks invalid; expected something like 'dev' or 'prod'." >&2
    exit 1
    ;;
esac
ITEM="agrippa-age-${ENV_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Stage 1: require bw present and unlocked, and yq available for Stage 4
PREFIX="rotate-keys"
# shellcheck source=lib/bw-status.sh
source "$SCRIPT_DIR/lib/bw-status.sh"
if ! command -v yq >/dev/null 2>&1; then
  echo "rotate-keys: yq is not available; it is required to update .sops.yaml safely." >&2
  exit 1
fi

# Receive confirmation for rotating keys before performing key rotation.
existing_json="$(bw list items --search "$ITEM" 2>/dev/null | jq --arg name "$ITEM" '[.[] | select(.name == $name)]' 2>/dev/null || echo '[]')"
existing="$(printf '%s' "$existing_json" | jq 'length' 2>/dev/null || echo 0)"
if [ "${existing:-0}" -gt 0 ]; then
  echo "rotate-keys: a Bitwarden item named '$ITEM' already exists -- about to rotate it. The old item is archived (renamed, not deleted) and a fresh identity is stored under the live name; .sops.yaml's recipient for secrets/${ENV_NAME}/.* is updated to match, and any already-committed secret under secrets/${ENV_NAME}/ is re-encrypted (sops updatekeys) using the archived key. Anything that can't be re-encrypted automatically is reported at the end for manual follow-up." >&2
  printf 'rotate-keys: type "rotate" to confirm: ' >&2
  confirmation=""
  read -r confirmation || true
  if [ "$confirmation" != "rotate" ]; then
    echo "rotate-keys: confirmation not given (got '$confirmation', need exactly 'rotate'); aborting, nothing changed." >&2
    exit 1
  fi
fi

# --- Stage 3: generate the keypair and store the private half in Bitwarden -
identity="$(age-keygen 2>/dev/null)"
if [ -z "$identity" ]; then
  echo "rotate-keys: age-keygen produced no output; aborting without contacting Bitwarden." >&2
  exit 1
fi
recipient="$(printf '%s\n' "$identity" | grep '^# public key: ' | sed -E 's/^# public key: //')"
if [ -z "$recipient" ]; then
  echo "rotate-keys: could not find a public-key line in age-keygen's output; aborting without contacting Bitwarden." >&2
  exit 1
fi

# The template carries only public, non-secret fields
tmpl="$(bw get template item | jq --arg name "$ITEM" '.type = 2 | .name = $name | .secureNote = {"type": 0} | .notes = null')"
item_json="$(printf '%s' "$identity" | jq -R -s --argjson item "$tmpl" '. as $n | $item + {notes: $n}')"

# Archives the old item under a distinct name instead of deleting it, so the
# prior identity stays recoverable in Bitwarden -- Stage 5 below uses it to
# re-encrypt already-committed secrets, and it remains available afterward for
# anything Stage 5 couldn't reach. old_identity is captured here (in memory
# only, never written to disk) before the item's name changes. Renaming
# happens before the new item is created so two items are never live under
# the same name at once. Reaching this point at all with existing>0 already
# means the "rotate" confirmation above was given -- there is no separate
# flag path that skips it.
old_identity=""
if [ "${existing:-0}" -gt 0 ]; then
  archived_at="$(date +%Y-%m-%d)"
  while IFS= read -r old_id; do
    [ -n "$old_id" ] || continue
    old_identity="$(bw get notes "$old_id" 2>/dev/null || true)"
    bw get item "$old_id" \
      | jq --arg name "${ITEM} (archived ${archived_at})" '.name = $name' \
      | bw encode \
      | bw edit item "$old_id" >/dev/null
  done < <(printf '%s' "$existing_json" | jq -r '.[].id')
fi
printf '%s' "$item_json" | bw encode | bw create item >/dev/null
unset identity item_json tmpl existing_json

echo "rotate-keys: stored a new age identity in Bitwarden as '$ITEM'."

# --- Stage 4: reflect the new recipient in .sops.yaml ----------------------
# .sops.yaml controls how NEW encryptions happen, and Stage 5 below depends on
# it already naming the new recipient: `sops updatekeys` re-wraps a file's
# data key for whatever recipients .sops.yaml's rule lists *at the time it
# runs*. Doing this update first means Stage 5 actually adds the new key;
# doing it after (the reverse order) makes updatekeys a silent no-op -- it
# sees the still-old recipient, decides nothing changed, and the secret stays
# readable only by the key being rotated away from.
SOPS_YAML=".sops.yaml"
if [ -f "$SOPS_YAML" ]; then
  export SOPS_ENV_PATH_REGEX="^secrets/${ENV_NAME}/.*\$"
  export SOPS_NEW_AGE="$recipient"
  old_age="$(yq '.creation_rules[] | select(.path_regex == env(SOPS_ENV_PATH_REGEX)) | .age' "$SOPS_YAML" 2>/dev/null || true)"
  if [ -n "$old_age" ] && [ "$old_age" != "null" ]; then
    yq -i '(.creation_rules[] | select(.path_regex == env(SOPS_ENV_PATH_REGEX)) | .age) = env(SOPS_NEW_AGE)' "$SOPS_YAML"
    echo "rotate-keys: updated $SOPS_YAML -- replaced the recipient for secrets/${ENV_NAME}/.* ."
  else
    yq -i '.creation_rules += [{"path_regex": env(SOPS_ENV_PATH_REGEX), "age": env(SOPS_NEW_AGE)}] | .creation_rules[].age style="double"' "$SOPS_YAML"
    echo "rotate-keys: added a new secrets/${ENV_NAME}/.* rule to $SOPS_YAML ."
  fi
  unset SOPS_ENV_PATH_REGEX SOPS_NEW_AGE old_age
else
  echo "rotate-keys: $SOPS_YAML not found; add this recipient for env '$ENV_NAME' by hand:" >&2
  echo "$recipient"
fi

# --- Stage 5: re-encrypt already-committed secrets under the new recipient -
# rotate-keys owns the whole environment's rotation record: sops updatekeys
# re-wraps a file's data key for whatever recipients
# .sops.yaml's rule now lists (the new key, just written above in Stage 4),
# but to do that it must first decrypt the file's current data key -- which
# needs the OLD private key. That's supplied only as SOPS_AGE_KEY, an
# environment variable sops itself reads, sourced from old_identity (never
# written to disk) and unset immediately after this stage.
secret_files=()
if [ -d "secrets/${ENV_NAME}" ]; then
  while IFS= read -r -d '' f; do
    grep -ql '^sops:' "$f" 2>/dev/null && secret_files+=("$f")
  done < <(find "secrets/${ENV_NAME}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.env' \) -print0)
fi
if [ "${#secret_files[@]}" -eq 0 ]; then
  echo "rotate-keys: no already-committed secrets under secrets/${ENV_NAME}/ to re-encrypt."
elif [ -z "$old_identity" ]; then
  echo "rotate-keys: no prior key to re-encrypt from (first-time key for '$ENV_NAME'); ${#secret_files[@]} secret(s) under secrets/${ENV_NAME}/ are already on the only key that has ever existed for this env."
else
  export SOPS_AGE_KEY="$old_identity"
  update_failed=()
  for f in "${secret_files[@]}"; do
    if sops updatekeys --yes "$f" >/dev/null; then
      echo "rotate-keys: re-encrypted $f"
    else
      update_failed+=("$f")
    fi
  done
  unset SOPS_AGE_KEY
  if [ "${#update_failed[@]}" -gt 0 ]; then
    echo "rotate-keys: could not re-encrypt ${#update_failed[@]} file(s); update these by hand with the archived key ('${ITEM} (archived ${archived_at})'):" >&2
    printf '  %s\n' "${update_failed[@]}" >&2
    exit 1
  fi
fi
unset old_identity