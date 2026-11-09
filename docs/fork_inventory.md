# Fork inventory

Actions, triggers and fixes added on `release/3.0` between `fa41b976`
(2026-10-28) and `32664f70` (2026-11-06), per provider: 63 merged pull
requests. Numbers in parentheses are pull requests of this repository.

## State

- Package status: Gmail, Google Calendar and Google Drive are
  `status(:available)`; Google Meet, Google Docs, Jira, Confluence and Tempo
  are `:experimental`. No package is on Hex, and `release/3.0` is not ready
  for external adoption (see [Branch support](branch_support.md)).
- `direct_mutation_mode` still defaults to `:allow`.
- Not covered:
  - The Meet transcript trigger was checked only against prepared meetings,
    not against a freshly ended one.
  - Shares of thread replies, bot messages and other authors' messages into
    the bot DM were never captured.
  - Closed Tempo periods, Scheduler freezes and grace periods: no public Tempo
    Cloud API reads them, so `tempo.period.bookability.get` reports an open
    period as `unknown`.

## Gmail (`jido_connect_gmail`)

New:

- `google.gmail.message.content.get` and `google.gmail.thread.content.get`:
  full text and thread context through a shared MIME traversal with
  configurable structural bounds, in the opt-in pack `:google_gmail_content`,
  under `gmail.readonly` (#12, #15).
- `google.gmail.message.attachment.content.get`: attachment bytes per MIME
  part, checked against the declared size; unnamed text parts that Gmail
  re-encodes fail with `:attachment_converted` (#21).
- `google.gmail.message.changed`: poll trigger for label changes and permanent
  deletion, covering archive, trash and restore (#27).

Changed:

- `messages.list` and `threads.list` with `q` require a read grant, because
  Google rejects `q` under `gmail.metadata` (#5).
- Outgoing MIME of `draft.create`, `draft.update`, `message.send` and
  `draft.send` rejects line breaks in headers and encodes non-ASCII subjects
  per RFC 2047 (#46, #49).

Checked live without new code: new-message polling, labels and archive (#32,
replayed offline in #35); forwards built by Outlook Web and Gmail Web, inline
and attached (#51).

## Google Calendar (`jido_connect_google_calendar`)

No new actions or triggers. `google.calendar.event.changed` fails a poll that
ends without `nextSyncToken` instead of replaying changes (#14). Event reads,
change polling and creation were checked live (#8), and the offline tests run
on recordings (#14, #62).

## Google Meet (`jido_connect_google_meet`)

New:

- `google.meet.transcript.entry.list`: transcript text per entry with
  participant, language and times, in the opt-in pack
  `:google_meet_transcript_reader` (#7).
- `google.meet.participant.get` and `google.meet.participant.list`: resolve an
  entry's speaker to display name, user type and `users/<id>` (#58).
- `google.meet.transcript.available`: poll trigger per connection over
  conference records in a time window, every 300 s, with a checkpoint of the
  settled end-time watermark plus pending records (#17, #28).

Checked: meeting-code lookup and recording reads (#19, #25). The Drive
`text/plain` export held the entry text in one of two prepared documents only,
so the entries are the reliable source (#60). The Meet live checks skip with a
reason once the prepared data expires on 2026-11-29 (#60).

## Google Drive (`jido_connect_google_drive`)

No new actions or triggers; existing ones changed:

- `file.get`, `file.export` and `file.download` take `resource_key`;
  `Link.parse/1` resolves shared links; shortcut targets are returned (#6).
- `files.list` returns `incomplete_search` (#13).
- `google.drive.collection.changes` finds its folder again, and the change
  feed for added and removed files is documented (#22).
- `file.upload` names the 5 MiB limit and fails above it with
  `:upload_too_large` (#26), and rejects Google Workspace types before the
  request (#57).
- `file.download` returns the stored bytes of JSON files (#39);
  `file.export` and `file.download` take an optional `max_bytes` (#56).
- The change dedupe key keeps a removal apart from a change at the same time;
  reads accept files without `name`; Apps Script exports return their bytes
  (#57).

Checked live: starred flag, modification time and an external Docs edit (#34,
#37).

## Google Docs (`jido_connect_google_docs`)

- `google.docs.document.get` returns tabs in Google's shape with nested child
  tabs (#9) and reads multi-tab documents under the `drive` grant (#54).
- `google.docs.document.batch_update` returns the write acknowledgement, and
  its snake_case wire format is pinned (#31).

## Slack (`jido_connect_slack`)

New:

- `slack.conversation.history`: history pages with full text, author and
  `ts`, with the bot or the user token; `Retry-After` is kept on `ok:false`
  errors (#10).
- Eight triggers `slack.event.message.{channels,groups,im,mpim}.{changed,deleted}`
  (#41).
- `slack.interactivity.block_actions` with verification of signed
  interactivity deliveries, and Block Kit buttons on `slack.message.post`
  (#16, #42).

Changed:

- Message triggers normalize file shares, broadcast replies and messages
  shared into a DM as `shared_messages` (#38).
- The authorizing user's view through user tokens; signals carry `view` (#48).
- `slack.conversation.open` resolves its client like `slack.message.post` and
  takes `conversation_type` (#20, #59).
- The app manifest enables the Messages tab, drops `scope_denied` and takes
  user scopes and user events (#59).

Checked live: `slack.thread.replies` over several pages in all four
conversation types, with the bot and the user token (#24, #29, #53).

## Jira (`jido_connect_jira`)

New: `jira.issue.comment.list`, comments page by page with text, ADF,
authors, times and visibility (#23).

Changed:

- `jira.issue.get` returns the description as text, due date, status and
  assignee, also by numeric ID; `jira.issue.search` uses the enhanced JQL
  search with `next_page_token`, and `start_at` and `total` are deprecated for
  one release (#18).
- Administrator webhook deliveries are verified with `verify_delivery/4`
  (`sha256=<hex>`) (#2); signals keep event names, actors and changelog
  identity (#30), and public maps keep changelog values (#55).
- Write paths encode the issue key as one path segment; an empty description
  stays `""` (#55).

## Confluence (`jido_connect_confluence`) and Atlassian (`jido_connect_atlassian`)

- New package `jido_connect_atlassian` with the shared ADF-to-text projection;
  Jira uses `:degrade`, Confluence `:fail` by default (#11).
- `confluence.page.get` returns the page's web URL and degrades unsupported
  content on request with `on_unsupported: :degrade` (#33).

## Tempo (`jido_connect_tempo`, new package)

- Foundation with the `:api_token` and `:oauth2_user` profiles, OAuth helpers,
  transport and pagination (#36).
- `tempo.worklogs.list_own` (#40), `tempo.work_attribute.list` and
  `tempo.account.list_for_project` (#50), `tempo.period.bookability.get` (#43,
  #52), `tempo.worklog.create` (#44), checked live with required work
  attributes and through the OAuth grant (#63).

## Shared and test infrastructure

- `:live_smoke` harness with sanitized recordings, captured deliveries and a
  leak guard (#1, #3, #61); offline tests run on recordings instead of
  hand-written stubs (#62 and per package). See
  [Live Smoke Tests](live_smoke_tests.md).
- Core: `Jido.Connect.WebhookDelivery.to_public_map/1` keeps one more level of
  the normalized signal (#55).

## Known defects

- In the Slack `ScopeResolver` clauses other than `conversation.open`, a
  declared `conversation_type` wins over the channel prefix.
  `slack.channel.archive` with a `G` ID and
  `conversation_type: "public_channel"` archived under a lease narrowed to
  `channels:manage`; `slack.conversation.invite` behaves the same. Found while
  building #59.
