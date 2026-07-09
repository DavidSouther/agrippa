# Refactor plan -- Feature 6 (Git hosting / Forgejo)

Scope: files touched by this feature-step (`git diff --name-only f55047b..HEAD`
at the point Step 4 went green). Mostly GitOps YAML (Kustomize/Helm
composition, sops-encrypted Secrets, one CNPG `Database` CR, one `HTTPRoute`)
-- no typed domain code, so the class-level/inheritance/parameter-list smells
in `references/abilities/refactor.md` don't apply here (same conclusion the
plan's own "Patterns beat" section already reached). Reviewed each touched
file for the smells that do transfer to declarative config: **Comments**
(illuminating vs. obscuring) and **Duplication**.

- [x] **Comments** (obscuring, not illuminating) --
  `platform/overlays/dev/forgejo/chart/kustomization.yaml:28-46`. Two adjacent
  `BUILD-TIME FINDING`/`BUILD-TIME CORRECTION` comment blocks both describe
  the same `gitea.additionalConfigFromEnvs` field from two angles (the
  confirmed `FORGEJO__DATABASE__PASSWD` env-var spelling, then a separate
  note correcting the entry's wrapping schema) -- reading as two
  half-finished notes about one decision rather than one coherent one.
  Merged into a single comment block covering both facts (the correct
  env-var name AND the correct EnvVar-object schema) in one place.

No other smells found in the remaining touched files (`namespace.yaml`,
`forgejo-database.yaml`, `httproute.yaml`, `kustomization.yaml` at each
level, `secrets/dev/platform/forgejo/*`, the `postgres-cluster.yaml` and
`gateway-cert.yaml` one-line appends) -- each is a small, single-purpose
file or a minimal append to an existing shared list, consistent with every
completed sibling feature's own file shapes; no duplication, no dead code,
no magic constants beyond the project's own established per-component
naming convention.
