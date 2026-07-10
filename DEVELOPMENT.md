# Development practices for Agrippa

## Commits

[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) with types `fix`, `feat`, `chore` and scopes `core` (Cluster Core), `store` (Storage), `otel` (Observability), `plat` (Platform), and `work` (Workloads).

## Testing

| Style | Tool | What it checks | How to run |
| --- | --- | --- | --- |
| Conformance | kubeconform | Every rendered manifest is schema-valid. | `mise run test:static` |
| unittest | helm-unittest | Chart template logic. | `mise run test:chart` |
| `SLOs` | OTel stack | Runtime reliability over weeks and months. Each app and workload ships an error budget (the SLO's complement) and burn-rate alerts. | Not a CI step. Defined with the workload, watched in Grafana. Must be present before launching an app. |
| `probers` | bats + curl | Black-box behavior against a running target. `chainsaw` for asserting resource reconcile. | `bats tests/` |

### CI lanes and mise tasks

| Lane | Command | Runs | Cluster |
| --- | --- | --- | --- |
| Per-push | `mise run test:push` | `test:static` (kubeconform + conftest), `test:chart` (helm-unittest), `test:tf` (terraform fmt/validate, tflint, terraform test, trivy config or checkov) | none |
| Per-PR | `mise run test:feature` | k3d up, apply the component, chainsaw + bats probes, k3d down | local k3d |
| Post-sync | `mise run test:gestalt` | `tests/agrippa.bats` against staging then live | deployed |

Budgets: per-push under 90s, feature under 10 min.

### Probers

Probers use [bats](https://github.com/bats-core/bats-core) driving `curl`. Install with `brew install bats-core` (pinned via mise once initialized). The test bodies are plain bash + curl; bats adds named cases, per-test isolation, and TAP output. Layout is one bats suite per feature under `tests/`, named after the feature:

- Add `tests/<feature>.bats` for ongoing feature probers.

```bash
bats tests/                 # every suite
bats tests/agrippa.bats     # one suite
```

Environment variables:

- `ENV` is `prod` (default) or `dev`.
- `PUBLIC_HOST`, `TRIPS_HOST`, `DASHBOARD_HOST` override target hostnames to point a suite at a local K3d ingress for local.
- `GRAFANA_USER`, `GRAFANA_PASSWORD` are local-only dev credentials (default `admin:admin`); never valid in production.

### Repo layout

Tests live alongside what they test:

- `tests/<feature>.bats` and `tests/<feature>/` (chainsaw dirs); `tests/policy/` (conftest Rego).
- `charts/<chart>/tests/` (helm-unittest).
- `.forgejo/workflows/` (steady-state CI), `.github/workflows/` (mirror CI during bootstrap).
- `mise.toml` at the repo root.

## Secrets

**SOPS + age**. Kubernetes `Secret`s and Terraform-consumed tokens are encrypted in git with `age` recipients, and
decrypted at apply time: through KSOPS in the ArgoCD repo-server for GitOps-managed layers, and
through `sops`/`helm-secrets` in the pre-ArgoCD bootstrap. Only the `age` private keys live outside git. 

### Key policy

- **Per-environment keys.** Separate `age` recipients for prod and k3d-dev, scoped via
  `.sops.yaml` path rules (e.g. `secrets/prod/.*` vs `secrets/dev/.*`). A leaked dev-machine key
  can't decrypt prod secrets. Promoting a secret from dev to prod means re-encrypting it under the
  prod key.
- **Rotation.** On demand with appropriate scripts, and monthly reminders.
- **Custody.** Each environment's `age` private key lives in Bitwarden as a secure-note item
  (`agrippa-age-prod`, `agrippa-age-dev`), never in git and never kept as a standing local copy.
  Scripted through the Bitwarden CLI: `bw unlock` for a session token, then
  `bw get notes agrippa-age-<env>`.

### How it's wired in

**Repo + tooling** (lands with `mise` init):

- One `age` keypair per environment from `age-keygen`; public recipients committed, private keys
  in Bitwarden.
- `.sops.yaml` at repo root, path-scoped per environment.
- `mise` tasks wrapping `sops` and `helm-secrets` for encrypt/edit and local k3d runs, pulling the
  `age` key through the Bitwarden CLI rather than expecting a standing local file.
- A `conftest`/CI guard in `test:static` that fails if any committed `kind: Secret` carries
  plaintext `data`/`stringData`.

**Terraform:**

- DigitalOcean and Cloudflare API tokens live in a sops-encrypted `terraform/secrets.enc.tfvars`
  (or via `sops exec-env`), decrypted by the operator's `mise` plan/apply task.
- Terraform (or cloud-init, writing into k3s's auto-deploy manifests directory) creates one
  injected Kubernetes `Secret`, `sops-age` in the `argocd` namespace, holding that environment's
  `age` private key — pulled from Bitwarden at apply time, never committed. This is the whole
  in-cluster trust root.

**k3s / ArgoCD:**

- The ArgoCD repo-server gets an init container installing `sops`/`kustomize`/`ksops`, with a
  volume mount of the `sops-age` Secret; KSOPS decrypts sops-encrypted manifests during
  `kustomize build`, transparently to every downstream Application.
- Encrypted secret manifests (e.g. `secrets/dev/storage/postgres/secret.enc.yaml`) are referenced
  by their kustomization and resolve at sync time.
- ExternalDNS and cert-manager's Cloudflare/DigitalOcean tokens are committed as sops-encrypted
  Secrets and decrypted the same way — one `age` trust root per environment, not a duplicated
  credential store.
