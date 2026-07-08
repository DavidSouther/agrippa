# Self-tests for the plaintext-Secret guard (tests/policy/secrets.rego).
#
# Discovered by `conftest verify --policy tests/policy tests/policy`
# (test:policy). Proves both directions of the guard plus the edge cases the
# plan calls out, so a regression in secrets.rego turns test:policy red.
package secrets

test_deny_plaintext_secret if {
	msgs := deny with input as {
		"kind": "Secret",
		"metadata": {"name": "plain-example"},
		"data": {"password": "cGxhaW50ZXh0"},
	}

	count(msgs) > 0
}

test_allow_sops_encrypted_secret if {
	msgs := deny with input as {
		"kind": "Secret",
		"metadata": {"name": "sops-example"},
		"data": {"password": "ENC[AES256_GCM,data:...,type:str]"},
		"sops": {"age": [{"recipient": "age1exampleexampleexampleexampleexampleexampleexampleexample"}]},
	}

	count(msgs) == 0
}

test_allow_metadata_only_secret if {
	msgs := deny with input as {
		"kind": "Secret",
		"metadata": {"name": "metadata-only"},
	}

	count(msgs) == 0
}

test_allow_secret_with_empty_data if {
	msgs := deny with input as {
		"kind": "Secret",
		"metadata": {"name": "empty-data"},
		"data": {},
		"stringData": {},
	}

	count(msgs) == 0
}

test_allow_non_secret_kind_with_data_field if {
	msgs := deny with input as {
		"kind": "ConfigMap",
		"metadata": {"name": "not-a-secret"},
		"data": {"password": "cGxhaW50ZXh0"},
	}

	count(msgs) == 0
}
