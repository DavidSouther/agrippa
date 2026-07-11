# Rotating an environment's age key

You arrived here because an `age` keypair for `agrippa-dev` (or another
environment) needs to change -- on a schedule, or because it may have leaked.
Read section 4 before you run anything: rotation and first-time key setup are
two different operations, and this script only does the first one.

---

## 1. The model in one paragraph

Each environment has exactly one `age` keypair. For `agrippa-dev` that
keypair's public half (the "recipient") is committed in `.sops.yaml` under
the `secrets/dev/.*` path rule, and its private half lives nowhere in git --
only as a Bitwarden secure-note item named `agrippa-age-dev`. Every committed
file under `secrets/dev/**/*.enc.yaml` is ciphertext, encrypted against that
public recipient; the plaintext it wraps never touches disk and is never
written to git. Decryption happens exactly once, at apply time, inside
ArgoCD's KSOPS-patched `argocd-repo-server`, which mounts the environment's
private key from the in-cluster `sops-age` Secret in the `argocd` namespace
and decrypts transparently during `kustomize build`. That `sops-age` Secret
is the live cluster's trust root; the Bitwarden item is the durable custody
record it was seeded from.

## 2. When to rotate, and the custody chain

`DEVELOPMENT.md`'s stated policy: rotate **on demand** (suspected leak, an
operator leaving the project, or any other reason to distrust the current
key) and as a **monthly reminder**, even with no known incident.

The private key only ever exists in two places at once, briefly, in memory:
Bitwarden and (after apply) the cluster's `sops-age` Secret. To read or write
it by hand:

```bash
bw unlock                       # prompts for your master password, prints a session token
export BW_SESSION="<token from above>"
bw get notes agrippa-age-dev    # prints the current private key material
```

`bw create item` / `bw edit item` are how you'd write a Bitwarden item by
hand, but for rotation itself you don't call these directly --
`scripts/rotate-keys.sh` does, as described below. There is no standing local
copy of the private key at any point; nothing in this flow writes it to a file
on disk.

## 3. Running rotation end to end

### What it needs

```bash
mise run rotate-keys
```

The underlying script is `scripts/rotate-keys.sh`, invoked with no
arguments for `agrippa-dev` (it defaults its environment name to `dev` via
the `AGRIPPA_ENV` environment variable, e.g. `AGRIPPA_ENV=dev`, which is
already the default). It refuses any `--flag`-style argument outright and
accepts at most one plain positional environment name (`[a-zA-Z0-9_-]+`,
e.g. `dev` or `prod`); confirmation happens interactively, not via a flag.
The `mise run rotate-keys` task itself declares no argument passthrough, so
for `agrippa-dev` the plain command above is correct as-is.

Before touching Bitwarden it checks two preconditions and exits immediately
if either is missing:

- `bw` (Bitwarden CLI) installed, logged in, and unlocked -- same check as
  `scripts/lib/bw-status.sh` uses elsewhere in this repo. If it's locked,
  the script tells you to run `bw unlock --raw` and export `BW_SESSION`
  first.
- `yq` installed -- required to edit `.sops.yaml` safely.

### What it does, stage by stage

1. **Looks up the Bitwarden item** named `agrippa-age-<env>`. If one already
   exists, it prints exactly what's about to happen and requires you to type
   the literal word `rotate` at an interactive prompt to proceed. Typing
   anything else aborts with nothing changed.
2. **Mints a fresh identity** with `age-keygen` and extracts its public
   recipient from the identity's own `# public key:` comment line.
3. **Archives the old Bitwarden item, then creates a new one.** The old item
   is renamed to `agrippa-age-<env> (archived YYYY-MM-DD)` -- not deleted --
   so the prior identity stays recoverable. Its private key material is held
   in memory only (never written to disk) as `old_identity`, captured before
   the rename. A brand-new item is then created under the original live name
   `agrippa-age-<env>` holding the new identity.
4. **Updates `.sops.yaml`.** Replaces the `age` value on the
   `secrets/<env>/.*` `creation_rules` entry with the new recipient (or adds
   the rule if this is the environment's first-ever key).
5. **Re-encrypts already-committed secrets.** For every file under
   `secrets/<env>/` that looks already-encrypted (matches `*.yaml`, `*.yml`,
   `*.json`, or `*.env` and contains a `^sops:` marker), it runs `sops
   updatekeys --yes` against it, with `SOPS_AGE_KEY` set (in-memory only,
   unset immediately after this stage) to the archived old identity, since
   decrypting the file's current data key still requires the old private
   key. Anything that fails to re-encrypt is reported at the end for manual
   follow-up, and the script exits non-zero.

### Verifying it worked

Two checks, both safe and read-only:

**`.sops.yaml`'s recipient actually changed:**

```bash
git diff .sops.yaml
```

You should see the old `age1...` value replaced by a new one on the
`secrets/dev/.*` rule -- nothing else in the file should move.

**A pod that mounts a re-encrypted secret still comes back healthy** after
the environment's `sops-age` Secret and the next ArgoCD sync catch up to the
new key. Pick any workload with a KSOPS-managed secret -- for example
Forgejo, which mounts `secrets/dev/platform/forgejo/admin.enc.yaml`:

```bash
export KUBECONFIG="$(k3d kubeconfig write agrippa-dev)"
kubectl config use-context k3d-agrippa-dev
kubectl -n forgejo get pods
kubectl -n forgejo rollout restart deployment forgejo
kubectl -n forgejo rollout status deployment forgejo
```

A clean restart to `Running`/`Ready` means the decrypted secret data KSOPS
handed it still matches what the app expects -- if the new recipient hadn't
actually made it into `.sops.yaml`, or the `sops-age` Secret in `argocd`
hadn't been updated to match, the repo-server would fail to decrypt during
its next `kustomize build` and the affected Application would go
`Unknown`/degraded well before the pod itself restarted.

---

## 4. STOP -- this is for replacing an existing key, not for filling in a placeholder

> **`mise run rotate-keys` rotates a key that already exists and is already
> trusted by the live cluster. It is the wrong tool if `.sops.yaml` still
> shows a placeholder value and no real key has ever been generated for this
> environment.**

Check what's actually committed before you decide which path applies:

```bash
grep -A2 'secrets/dev' .sops.yaml
```

`.sops.yaml`'s comment block above the `secrets/dev/.*` rule opens with
"PLACEHOLDER recipient -- replace with the real agrippa-age-dev public key"
and goes on to note that `mise run rotate-keys` updates the file
automatically on future rotations, but the `age:` value beneath it is a
real, operative key
(`age1e8wr0f85w0yfqgxc3pc6426ghlu5xt069znn5yuwrtwz30u23quqjcx6vc`), matching
what's live in the cluster's `sops-age` Secret in the `argocd` namespace.
The comment is stale documentation, not a signal that setup is still
pending -- confirm the live value yourself with the `grep` above rather than
trusting the comment.

If you ever do hit a real placeholder-vs-generated mismatch -- a fresh
environment where `.sops.yaml`'s `age:` value is a literal placeholder
string and Bitwarden already holds a real `agrippa-age-<env>` item (seeded
by whatever bootstrapped the cluster) -- the fix is a plain, non-destructive
edit that reads the key straight out of Bitwarden and writes it into
`.sops.yaml`:

```bash
bw unlock
export BW_SESSION="<token>"
key="$(bw get notes agrippa-age-dev | grep '^# public key: ' | sed -E 's/^# public key: //')"
yq -i '(.creation_rules[] | select(.path_regex == "^secrets/dev/.*$") | .age) = env(key)' .sops.yaml
```

**Do not reach for `rotate-keys` here.** `scripts/rotate-keys.sh` looks up
the Bitwarden item first; if `agrippa-age-<env>` already exists, it treats
that as "an old key to replace" -- and on confirmation it **archives that
item and mints a brand-new identity**, regardless of whether `.sops.yaml`
was ever caught up to it. Run it against a fresh-looking `.sops.yaml` and
you don't fix the placeholder -- you generate a second new key, orphaning
whatever trust root the live cluster's `sops-age` Secret was already seeded
with from the *first* real key sitting in Bitwarden. The comment does not
match the committed key: the `age:` value is real and trusted, while the
comment still describes a placeholder. Confirm the live value with the
`grep` above rather than trusting the comment.

---

## 5. The rotation script's stage ordering

`scripts/rotate-keys.sh` reflects the new recipient in `.sops.yaml` (its
`## Reflect the new recipient in .sops.yaml` block) before re-encrypting
already-committed secrets (its `## Re-encrypt already-committed secrets under
the new recipient` block), so the re-encryption pass always targets the
current recipient. `sops updatekeys` re-wraps a file's data key for whatever
recipients `.sops.yaml`'s matching rule currently lists, so the recipient has
to be current before that pass runs. `tests/rotate-keys.bats` asserts a
decrypt under the new key end to end.

No extra caution or dry run is needed beyond the "Verifying it worked" checks
in section 3, which remain the right place to confirm any given rotation
actually took.
