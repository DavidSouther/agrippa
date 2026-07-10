# Plaintext-Secret guard (DEVELOPMENT.md ## Secrets).
#
# Denies any `kind: Secret` manifest that carries non-empty `data` or
# `stringData` and is not SOPS-encrypted (no `sops` block). Allows a
# SOPS-encrypted Secret (ciphertext lives under `data`/`stringData`, but the
# manifest also carries the `sops` metadata block KSOPS/sops-encrypted
# manifests always have), a metadata-only Secret (no `data`/`stringData` at
# all), and a Secret with `data: {}` or `stringData: {}` present but empty.
# Never evaluates non-Secret kinds (e.g. a ConfigMap with a `data` field).
package secrets

deny contains msg if {
	input.kind == "Secret"
	is_plaintext(input)
	msg := sprintf("Secret %s carries plaintext data", [input.metadata.name])
}

is_plaintext(secret) if {
	not secret.sops
	count(object.union(
		object.get(secret, "data", {}),
		object.get(secret, "stringData", {}),
	)) > 0
}
