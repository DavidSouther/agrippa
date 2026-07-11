# secrets/dev/platform/keycloak

Two sops-encrypted Secrets, KSOPS-decrypted at `kustomize build` time by the
ArgoCD repo-server (see `secret-generator.yaml`; DEVELOPMENT.md's Secrets
section for the general mechanism). Edit via `sops` in place -- never commit
a decrypted or `stringData:` version of either file.

## keycloak-admin.enc.yaml

The bootstrap admin user, referenced by
`platform/overlays/dev/keycloak/keycloak.yaml`'s `spec.bootstrapAdmin.user.secret`.
Regenerate on initial creation or whenever this credential needs rotating
(compromise, or replacing a dev placeholder password):

```bash
kubectl create secret generic keycloak-admin \
  --namespace keycloak \
  --from-literal=username=<admin username> \
  --from-literal=password=<new password> \
  --dry-run=client -o yaml \
  | sops --config <repo root>/.sops.yaml -e /dev/stdin \
  > keycloak-admin.enc.yaml
```

## keycloak-db.enc.yaml

The `keycloak` Postgres role's credentials, referenced by
`platform/overlays/dev/keycloak/keycloak.yaml`'s `spec.db.usernameSecret`/
`passwordSecret` -- must live in the `keycloak` namespace (the Keycloak
Operator requires the connection Secret to be same-namespace as the `Keycloak`
CR).

**This is a second copy of the same credential, not the only one.** CNPG's
`managed.roles[]` mechanism (`storage/overlays/dev/postgres-cluster.yaml`,
role `keycloak`) has its own `passwordSecret: keycloak-db`, which CNPG
requires to live in the `storage` namespace (same-namespace-only, like the
`Database` CR) -- that's `secrets/dev/storage/postgres/keycloak.enc.yaml`, a
different file. Both Secrets must hold the identical username/password:
rotating one without the other in the same change leaves Keycloak
authenticating with a password CNPG no longer recognizes for that role, and
Keycloak's pod fails to connect (silently, until the next restart surfaces
it).

To rotate: pick the new password once, then regenerate **both** files in the
same change:

```bash
kubectl create secret generic keycloak-db \
  --namespace keycloak \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=keycloak \
  --from-literal=password=<new password> \
  --dry-run=client -o yaml \
  | sops --config <repo root>/.sops.yaml -e /dev/stdin \
  > keycloak-db.enc.yaml
```

then the matching update to `secrets/dev/storage/postgres/keycloak.enc.yaml`
(same recipe, `--namespace storage`, same new password). Confirm the existing
file's exact `type:`/field shape with `sops -d` first if unsure -- sops
encrypts values, not field names, so `cat`ting either `.enc.yaml` shows the
real structure even without decrypting.
