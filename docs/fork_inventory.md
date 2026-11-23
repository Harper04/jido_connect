# Fork inventory

What `release/3.0` of this fork adds over `upstream/release/3.0` at
`22772cbf`, per provider. Numbers in parentheses are pull requests of this
repository. The branch is upstream plus one commit per area; the state before
that rebuild is the tag `archive/release-3.0-2026-11-23`.

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

Fixed: a supplied `conversation_type` never lowers the scope that the
channel ID or the participant set requires, `slack.conversation.history`
included (#66).

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
  identity (#30).
- `Jido.Connect.Jira.Webhook.to_public_map/1` from upstream keeps the values
  of status and priority changes; this fork adds due-date changes, the other
  half of the status and due-date evidence (#55, rebuild). Assignee values
  stay out of the public map, as upstream decided; the signal carries them.
- Write paths encode the issue key as one path segment; an empty description
  stays `""` (#55).
- Issue reads and comments keep upstream's `description_adf_error` and
  `body_adf_error`; the fork's fields `missing_fields`, `url`, `body_adf` and
  `visibility` sit next to them (#18, #23).

## Confluence (`jido_connect_confluence`)

`confluence.page.get` returns the page's web URL and reads the page through
upstream's ADF projection, failing on unsupported content by default and
degrading it on request with `on_unsupported: :degrade` (#33). Unlike
upstream's strict `Confluence.ADF.to_text/1`, the projection keeps link
targets in parentheses, indents nested lists and reads links of any scheme,
also in the default mode. The shared package `jido_connect_atlassian` is
upstream's.

## Tempo (`jido_connect_tempo`, new package)

- Foundation with the `:api_token` and `:oauth2_user` profiles, OAuth helpers,
  transport and pagination (#36).
- `tempo.worklogs.list_own` (#40), `tempo.work_attribute.list` and
  `tempo.account.list_for_project` (#50), `tempo.period.bookability.get` (#43,
  #52), `tempo.worklog.create` (#44), checked live with required work
  attributes and through the OAuth grant (#63).

## Shared and test infrastructure

- The `:live_smoke` harness is upstream's. This fork adds review fixes on top:
  concurrent responses of one test are numbered under a lock, JSON scalars
  are recorded, the leak guard reads percent escapes in either case, names
  never change addresses or placeholders, and the address patterns run in
  linear time. Its variable registry and
  [Live Smoke Tests](live_smoke_tests.md) list the variables of this fork's
  live tests. Offline tests run on recordings instead of hand-written stubs
  (#62 and per package).
- The demo host's capture is upstream's. This fork adds a capture-only Jira
  route, `/integrations/jira/webhook`, that writes a delivery only after its
  signature verifies with `JIRA_WEBHOOK_SECRET`.

## Dropped in the rebuild

- The core change that kept one more level of the normalized signal in
  `Jido.Connect.WebhookDelivery.to_public_map/1` (#55). The Jira map above
  covers the values it was for.
- The fork's own ADF projection, Confluence delegation and Jira rendering
  (#11): upstream's `jido_connect_atlassian` replaces them.
- The fork's demo capture of all request headers before verification (#1):
  upstream's capture writes verified deliveries only.
- `CHANGELOG.md` entries: upstream generates release notes from commit
  history.

## Behaviour that follows upstream

- A Jira description or comment body that the ADF projection cannot render
  no longer fails the read, the search page, the comment list or the comment
  signal. The result keeps its other fields and names the reason in
  `description_adf_error`, `body_adf_error` or `comment_body_adf_error`.
- Recording refuses to replace an existing fixture; delete it or record under
  `:root` before recording it again.
- The public Jira map has no changelog `id`, no `field_id`, no `null`
  values (a cleared assignee or due date has no `to`) and no items of other
  fields; before the rebuild the core map kept them all on one more level.
- The demo host writes Slack and Jira captures to `slack-<n>.json` and
  `jira-<n>.json` with only the signature, Jira's delivery identifier and
  flow and the content type, in at most 20 slots per directory. The live
  tests also read batches moved into subdirectories.
