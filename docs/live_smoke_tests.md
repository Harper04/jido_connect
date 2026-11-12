# Live Smoke Tests

Live smoke tests call a provider's real API with a dedicated test account. They
check that a connector works against the provider and supply the recorded
responses that offline tests use as `Req.Test` fixtures. A response shape
written from memory or from documentation alone is not a recording.

The convention lives in `Jido.Connect.TestSupport.LiveSmoke`
(`apps/jido_connect/test/support/live_smoke.ex`). Live runs happen only on a
developer machine with credentials in the shell. They never run in CI.

## Running

Every live test carries the `:live_smoke` tag. The test helpers of the packages
that adopt the convention start ExUnit with `exclude: [:live_smoke]`, so a plain
`mix test` never calls a provider. Export the provider's variables and run the
live tests of one package from the umbrella root:

```sh
set -a; source /path/to/slack.env; set +a
MIX_ENV=test mix do --app jido_connect_slack test --only live_smoke
```

The env file is a local file outside the repository with plain `NAME=value`
lines, so `set -a` exports them to `mix`. `mix test --only live_smoke` inside
the app directory works too, except in packages that declare `plug` as a
test-only dependency: there Mix reports a conflict with a transitive
dependency.

A package adopts the convention with these `test_helper.exs` lines:

```elixir
ExUnit.start(exclude: [:live_smoke])

unless Code.ensure_loaded?(Jido.Connect.TestSupport.LiveSmoke) do
  Code.require_file("../../jido_connect/test/support/live_smoke.ex", __DIR__)
end
```

## Writing a Live Test

```elixir
defmodule Jido.Connect.Slack.LiveSmokeTest do
  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  @tag env!(["SLACK_BOT_TOKEN"])
  test "auth.test accepts the bot token", %{env: env} do
    LiveSmoke.record({:jido_connect_slack, :slack_req_options}, :slack, "auth_test")
    assert {:ok, _identity} = Jido.Connect.Slack.Client.auth_test(env["SLACK_BOT_TOKEN"])
  end

  @tag env!(["SLACK_BOT_TOKEN", "SLACK_PUBLIC_CHANNEL_ID"])
  @tag write!(:slack)
  test "posts and deletes a message", %{env: env} do
    # ...
  end
end
```

`use LiveSmoke` tags the module with `:live_smoke`, imports `env!/1` and
`write!/1`, and adds a setup that puts the variable values into the test
context under `:env`.

`env!/1` takes the variable names a test needs; list them all in one call,
because a second `env!/1` tag on the same test replaces the first list. It
rejects names that this document does not list, so a typo fails at once. When
a variable is unset or empty, the test is skipped and the reason names the
variable. ExUnit does not print skip reasons, so a run that includes
`:live_smoke` prints a line such as:

```text
live_smoke skip test/jido_connect/slack/live_smoke_test.exs:5: set SLACK_BOT_TOKEN to run this live test
```

`write!/1` marks a test that changes data in the provider account. The test is
skipped unless `<PROVIDER>_LIVE_DESTRUCTIVE=true`. If a skipped test runs
anyway, for example with `--include skip`, the setup raises for an unset or
empty variable and refuses a write while the gate is closed. A `setup_all`
callback runs before that check, so keep provider calls out of `setup_all`.

Use `async: false`: recording changes application environment and runs one
recorder per test.

## Variables

Credentials live in a password manager and in local, uncommitted env files,
sourced into the shell before a run. They never go into the repository, CI, a
fixture or an issue comment. Values marked as credentials below are checked by
the leak guard of every recording, and so is every set variable whose name
ends in `TOKEN`, `SECRET`, `PASSWORD` or `API_KEY`. Email addresses in
listed settings and in variables ending in `_EMAIL` are guarded too.

The list holds only the variables of live tests that use this module. A change
that adds a provider's first such test adds a section for that provider here,
with its credentials, its settings and its `<PROVIDER>_LIVE_DESTRUCTIVE` gate,
and the same names to the variable list in `LiveSmoke`. A test in
`jido_connect` checks that both lists agree.

### Slack

The variables of the example above, which the tests of the harness itself also
read.

| Variable | Kind | Meaning |
| --- | --- | --- |
| `SLACK_BOT_TOKEN` | credential | Bot token of the test app |
| `SLACK_PUBLIC_CHANNEL_ID` | setting | Public channel |
| `SLACK_LIVE_DESTRUCTIVE` | gate | `true` allows write tests |

## Recording

With `JIDO_CONNECT_RECORD=1`, `LiveSmoke.record/4` records the responses of
the current test:

```elixir
LiveSmoke.record({:jido_connect_slack, :slack_req_options}, :slack, "auth_test")
```

The first argument names the package's existing Req test options. The recorder
joins them as the Req adapter until the test exits; it runs the normal Finch
adapter and appends a response step. Each final response, after retries and
redirects, is sanitized and written to
`test/fixtures/<provider>/recorded/<name>.json` in the package. A second
response in the same test goes to `<name>.2.json`, a third to `<name>.3.json`.
Responses that finish at the same time are written one after the other and
numbered in that order. A new recording overwrites files of the same name;
delete numbered files that a shorter run no longer writes. Without
`JIDO_CONNECT_RECORD=1` the call does nothing, so live tests keep the call in
place. Recording refuses to start while the Req options contain `:plug`,
because a plug replaces the network.

The recorder's step runs after the response steps that the package attached
when it built the request, Req's body decoding among them. Redaction by key
needs that decoded body. A package that sets `decode_body: false`, or decodes
in a step of its own that runs later, hands the recorder a string: then only
the rules for free text apply, and token fields such as `access_token` stay in
clear text. The leak guard catches only the credentials it knows, not a token
the provider has just issued. Keep decoding in a step that is attached when
the request is built.

A test account that real users share returns their data next to the test data,
and the sanitizer does not know which is which. The `:transform` option of
`record/4` takes a function of the decoded request path and the decoded
response body that returns the body to record, or `:skip` to write no fixture
for that response:

```elixir
LiveSmoke.record({:jido_connect_slack, :slack_req_options}, :slack, "history",
  transform: fn
    "/api/conversations.history", %{"messages" => messages} = body ->
      %{body | "messages" => Enum.filter(messages, &(&1["bot_id"] == bot_id))}

    _path, body ->
      body
  end
)
```

The transform runs before the sanitizer, so the leak guard checks its result.
It changes only the fixture; the caller still gets the response as the provider
sent it. A skipped response takes no number. Use it only to leave out or
neutralize data that must not be committed, and say in the test what it
changes, since the fixture then differs from the provider's answer.

A fixture file holds the recording date, the request method and the decoded
path without query, the status, the sanitized response headers and the
sanitized body. When the transform returned a body other than the provider's,
the file also holds `"transformed": true`; its headers, such as
`content-length`, still describe the provider's response. A body that is not
UTF-8, such as a file download, is stored as `"body": null` with `body_bytes`
and `body_sha256`:

```json
{
  "body": {"id": "user-1", "email": "person-1@example.com"},
  "headers": {"content-type": ["application/json"]},
  "recorded_at": "2026-10-30",
  "request": {"method": "GET", "path": "/v1/profile"},
  "status": 200
}
```

Offline tests load the body with `LiveSmoke.fixture!/2`, which returns it
unchanged:

```elixir
Req.Test.stub(MyStub, &Req.Test.json(&1, LiveSmoke.fixture!(:slack, "auth_test")))
```

Default test runs do not play recordings back on their own; each package
wires its fixtures into its offline tests. Commit only the fixtures that an
offline test loads.

## Reviewing Fixtures

`LiveSmoke.sanitize_fixture/2` sanitizes a fixture file's content again, in
the recorder's order; keys other than the body, the headers and the request
path, such as `transformed`, stay as they are.
`apps/jido_connect/test/jido_connect/test_support/live_smoke_fixtures_test.exs`
runs it over every committed recording of the umbrella: a fixture that the
current sanitizer would change, or that holds a guarded value, fails the test,
which names the file and the changed keys but no value. The test passes no
options; `sanitize_fixture/2` with a recording's own options, such as
`fields:`, checks it the way it was recorded.

Fixtures written by hand go under `test/fixtures/<provider>/synthetic/`. The
same test runs `LiveSmoke.check_leaks!/2` over them, which applies the leak
guard to the file as it is, so a credential under a key the sanitizer would
redact is found too.

Without credentials in the environment the guard knows only the values it
learns. Before committing new fixtures, run the test once with the provider's
env file loaded:

```sh
(set -a; source /path/to/slack.env; set +a
 cd apps/jido_connect && mix test test/jido_connect/test_support/live_smoke_fixtures_test.exs)
```

A second run sees only what the fixture still holds. It does not know a value
that the first run learned from a part it then replaced, such as a name from
a `displayName`, and so cannot find that value where the first run left it in
free text.

## Sanitizing

Recordings pass through the sanitizer, also available as
`LiveSmoke.sanitize/2` and `LiveSmoke.sanitize_fixture/2`:

- Headers whose names contain `auth`, `cookie`, `token`, `secret` or
  `signature`, the forwarding headers, `x-amz-cf-pop`, which names the
  CloudFront edge that served the response, and every header that
  `Jido.Connect.Sanitizer.sensitive_key?/1` reports are dropped.
- Values under the sensitive keys of `Jido.Connect.Sanitizer` become
  `"[redacted]"`. `fields` is kept by default, because Jira and Airtable
  return record content under it, and is sanitized like any other value; pass
  `keep_keys:`, which names keys exactly as they appear, to change that. The
  `fields:` option below is a different thing.
- Email addresses in values, in map keys and in the request path become
  `person-<n>@example.com`.
- Display names become `Person <n>`. They are taken from keys such as
  `displayName`, `real_name`, `publicName` and `username`, and from address
  lists such as `Ada Lovelace <ada@example.org>, bob@example.org`. Once known,
  a name is replaced as a whole word, ignoring case, wherever it appears. Pass
  `name_keys:` for more keys, such as Slack's `name`.
- Values under the keys given as `fields:` become `<field>-<n>`, for message
  text or other content a fixture does not need. Map keys inside such values
  are sanitized as above.
- Placeholders are stable within one recording: the same input gets the same
  placeholder. Sanitizing sanitized output again keeps its placeholders, also
  the `<field>-<n>` ones, with or without the recording's `fields:`, and a
  value learned on that run gets a number that no placeholder in the input
  holds. Names are never replaced inside email addresses or placeholders, so
  a name such as `Person` or `example.com` leaves them whole.
- If the value of a credential variable, eight bytes or longer, or a guarded
  email address still appears in the output, raw, JSON- or form-encoded,
  percent-escaped in either case, or Base64-encoded at any position inside
  longer Base64 content, the sanitizer raises `LiveSmoke.LeakError`. The
  message names the variable, not the value, and nothing is written.

These rules know no provider. Identifiers that only one provider uses, such as
a tenant host in URLs or an account ID that the provider repeats in links and
headers, need a rule of their own. The change that records the first fixture
holding such an identifier adds the rule to
`Jido.Connect.TestSupport.LiveSmoke.Sanitize`, with a test in
`live_smoke_test.exs`; the fixture review then checks every committed fixture
against it.

Remaining limits:

- Free text keeps names that never appear under a name key or in an address
  list, and names shorter than three bytes or longer than 200 bytes are not
  learned. Content such as message text, issue summaries and page bodies
  stays unless listed in `fields:`.
- A learned name that is also an ordinary word, such as a username `api`, is
  replaced wherever it stands as a word, URLs included.
- IDs, hosts and other identifiers stay unless a rule covers them, and the
  leak guard knows only the variables above. It compares values in the case
  they are configured; an email address in another case is replaced only
  where it appears in clear text.
- The leak guard finds a guarded value in Base64 content only when its own
  encoding appears unbroken, not across a line break. It does not decode a
  value that was encoded twice.
- Other response headers can still name the serving edge or region.

Review every recording before committing it.

## Evidence

A live run counts as evidence when its report names the date, the test, the
result, the provider object IDs and counts it observed, and SHA-256 digests of
the recorded files it relies on:

```sh
shasum -a 256 apps/jido_connect_slack/test/fixtures/slack/recorded/auth_test.json
```

A report never contains credentials, message text, document content or other
account content. IDs of test objects are fine; they also appear in env files
and test settings. ExUnit prints the arguments of a failing call, which in a
live test can include a token, so do not paste raw failure output into a
report.
