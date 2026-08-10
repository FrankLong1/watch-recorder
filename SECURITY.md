# Security and public-repository boundary

This repository contains generic application, server, and deployment code. It
must not identify or grant access to a real person, Apple account, device, GCP
project, database, service, or workstation.

## Public and tracked

- Apple-platform source and neutral bundle defaults
- Server source, migrations, and generic Terraform
- Placeholder configuration examples
- Tests and product/architecture documentation

## Private and local only

- `.env` and every token or API key
- `terraform.tfvars`, plans, state, live URLs, project IDs, instance names, and
  service-account addresses
- `Signing.local.xcconfig`, Apple team IDs, and personal bundle prefixes
- Device names, provisioning status, workstation paths, logs, audio,
  transcripts, and databases
- `.private-patterns`, an optional local list of identifiers that must never
  appear in tracked files

The application preserves audio locally until the next durable hop confirms
receipt. Audio and transcripts must never be committed to Git.

## Before publishing

Run:

```bash
./scripts/check-public.sh
```

GitHub runs the same check for pushes and pull requests. GitHub secret scanning
is additional defense, not permission to place secrets in a commit. If a real
credential is ever committed, revoke or rotate it immediately before considering
a coordinated history rewrite.
