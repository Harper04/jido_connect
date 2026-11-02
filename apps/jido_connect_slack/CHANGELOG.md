# Changelog

## Unreleased

- Keep Slack's `Retry-After` header as `details.retry_after` on `ok: false`
  responses, such as a 429 `ratelimited`, as other HTTP errors already do. This
  changes the error details of every Slack action.

## 0.1.0

- Add the initial Slack provider for Jido Connect with generated Jido modules,
  OAuth helpers, Web API client helpers, and signed request verification.
