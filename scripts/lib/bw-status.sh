#!/usr/bin/env bash
# Check bitwarden status before running any commands that need its out-of-cluster secrets.
#
# Fails loudly, names the missing prerequisite, and ensures no plaintext fallback.
# This is a human-resolved blocker (`bw login` / `bw unlock`), not something this task works around.
# Caller should set PREFIX to the current sceop type for good error messages.
# Exits non-zero on any Bitwarden CLI absence/lock/auth failure.
: "${PREFIX:?scripts/lib/bw-status.sh requires PREFIX to be set}"

if ! command -v bw >/dev/null 2>&1; then
  echo "${PREFIX}: bw (Bitwarden CLI) is not installed. Install it (e.g. \`brew install bitwarden-cli\`), then \`bw login\` and \`bw unlock\`, and re-run." >&2
  exit 1
fi
bw_status="$(bw status --raw 2>/dev/null | jq -r '.status' 2>/dev/null || echo unknown)"
case "$bw_status" in
  unlocked) ;;
  locked)
    echo "${PREFIX}: Bitwarden vault is locked. Run 'echo BW_SESSION=\"\$(bw unlock --raw)\" > .env' then re-run." >&2
    exit 1
    ;;
  unauthenticated)
    echo "${PREFIX}: not logged into Bitwarden. Run 'bw login', then 'echo BW_SESSION=\"\$(bw unlock --raw)\"', then re-run." >&2
    exit 1
    ;;
  *)
    echo "${PREFIX}: could not determine Bitwarden CLI status (\`bw status\` returned '$bw_status'). Ensure bw is installed, logged in, and unlocked (BW_SESSION set)." >&2
    exit 1
    ;;
esac
