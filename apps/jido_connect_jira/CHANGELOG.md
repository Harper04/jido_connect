# Changelog

## Unreleased

- Add Jira Software board actions, saved-filter actions, issue transition
  discovery, destructive issue deletion, and Jira plan administration actions.
- Add strict nested plan validation, safe write previews, destructive gates,
  Jira administration policy requirements, and focused catalog packs.
- Disable automatic retries for filter share replacement and preserve uncertain
  delivery details for non-idempotent writes.
- Verify Jira administrator webhook signatures (`X-Hub-Signature:
  sha256=<hex>`) in `Jido.Connect.Jira.Webhook.Verification`, add
  `Jido.Connect.Jira.Webhook.verify_delivery/4`, and declare `:hmac_sha256` on
  both webhook triggers. `verify_signature/2` and `compute_signature/2` stay as
  legacy base64 helpers.

## 0.1.0

- Add the Jira provider package scaffold for Jido Connect.
