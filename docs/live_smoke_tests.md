# Live smoke tests

Use a dedicated test account with synthetic data. Tag live tests with
`:live_smoke`. In each package that adds one, exclude the tag in
`test/test_helper.exs` and load the shared helper.

```elixir
ExUnit.start(exclude: [:live_smoke])

unless Code.ensure_loaded?(Jido.Connect.TestSupport.LiveSmoke) do
  Code.require_file("../../jido_connect/test/support/live_smoke.ex", __DIR__)
end
```

In the live test module, use `ExUnit.Case, async: false` and
`Jido.Connect.TestSupport.LiveSmoke`. Use `@tag env!([...])` to declare
required variables. The helper skips the test if a variable is empty or
unset. A test that writes to the provider also uses `@tag write!(:provider)`.
The write gate requires the corresponding variable to equal `true`.

Run live tests explicitly from the umbrella root.

```sh
MIX_ENV=test mix do --app jido_connect_slack test --only live_smoke
```

## Recording and replay

Set `JIDO_CONNECT_RECORD=1` to enable recording. In the test, call
`LiveSmoke.record({app, req_options_key}, provider, name)` before the request.
The recorder installs a temporary Req adapter. Keep recording tests serial.
The recorder writes the response status, sanitized path, headers and body into
`test/fixtures/<provider>/recorded`. Each subsequent response gets a numbered
file name; responses of one test that finish at the same time are written one
after the other and numbered in that order. A recording fails if the
destination already exists. To refresh a fixture, record with `:root` set to
a temporary directory. Review the new files before replacing the old ones.
Keep only the files that tests use.

Leave Req body decoding enabled for structured responses. The recorder can
redact fields by key when it receives a decoded body. A test can use
`:transform` to reduce the recorded body or skip a response. Document any
transform that changes the fixture. Load the body in an offline test with
`LiveSmoke.fixture!/2`.

For inbound delivery replay, pass a signed capture and the provider signing
secret to `LiveSmoke.write_capture!/4`. It verifies the original Slack or Jira
signature, sanitizes the capture and signs it with the fixture key. Pass the
sanitized file and a provider that implements `verify_delivery/4` to
`LiveSmoke.replay/2`. The Slack and Jira connectors supply this verifier.
Use a fresh destination for each capture. Capture conversion also fails if
the destination already exists.

## Fixture review

Keep credentials in a password manager or a local file outside the
repository. Load them into the shell for the test. Keep raw captures
outside the repository. Use synthetic content wherever possible.

The sanitizer removes sensitive headers and keys, replaces recognized
identifiers, and checks for known values in several encodings, percent escapes
in either case included. Learned names are never replaced inside email
addresses or placeholders, and names longer than 200 bytes are not learned. Opaque or
nested content can still contain private data. Review every request path,
header and body before committing a fixture. Check encoded text, attachments,
provider identifiers and tenant URLs. Remove files that the tests do not load.

Run the fixture checks with the test credentials and settings loaded. A
failure identifies the file and affected fields. A passing check means that
the scanner found no known leaks in the files it inspected.

```sh
mix test apps/jido_connect/test/jido_connect/test_support/live_smoke_fixtures_test.exs
```

Report the test date, command, result and the digest of each reviewed fixture.
Keep credentials, response content and raw assertion output out of reports.

## Variables

Add provider-specific variables when a provider adopts the helper. Use
`JIDO_CONNECT_RECORD=1` only when you intend to write fixtures. The leak check
also checks nonempty variables whose names end in `_TOKEN`, `_SECRET`,
`_PASSWORD` or `_API_KEY`.

### Google Workspace

| Variable | Kind | Meaning |
| --- | --- | --- |
| `GOOGLE_CLIENT_ID` | setting | OAuth client of the test Cloud project |
| `GOOGLE_CLIENT_SECRET` | credential | OAuth client secret |
| `GOOGLE_REFRESH_TOKEN` | credential | Refresh token with the full test scopes |
| `GOOGLE_ACCESS_TOKEN` | credential | Access token minted per run from the refresh token |
| `GOOGLE_GMAIL_METADATA_REFRESH_TOKEN` | credential | Refresh token with `gmail.metadata` only |
| `GOOGLE_GMAIL_METADATA_ACCESS_TOKEN` | credential | Access token minted from it |
| `GOOGLE_DRIVE_ONLY_ACCESS_TOKEN` | credential | Access token narrowed to `drive`, minted per run from `GOOGLE_REFRESH_TOKEN` by a refresh with `scope=https://www.googleapis.com/auth/drive`; use it only when the `scope` field of the refresh response is exactly that scope |
| `GOOGLE_GMAIL_QUERY` | setting | Query matching exactly five prepared messages, two of them archived |
| `GOOGLE_GMAIL_THREAD_ID` | setting | Three-message conversation |
| `GOOGLE_GMAIL_ATTACHMENT_MESSAGE_ID` | setting | Message with attachments and nested parts |
| `GOOGLE_GMAIL_FORWARD_INLINE_ID` | setting | Inline forward |
| `GOOGLE_GMAIL_FORWARD_ATTACHED_ID` | setting | Forward as attachment |
| `GOOGLE_GMAIL_FORWARD_OPAQUE_ID` | setting | Forward with an empty and a header-only `message/rfc822` part, both of which Gmail splits into nested parts |
| `GOOGLE_GMAIL_FORWARD_RELATED_ID` | setting | Forward as attachment in the shape Outlook Web builds: outer and enclosed text in `multipart/alternative`, the HTML with two and one inline images in a `multipart/related` inside it, each image with a `Content-ID` in Outlook's form, an rfc822 part whose disposition names no file, an outer subject other than the enclosed one, and a file attachment in the enclosed forward |
| `GOOGLE_GMAIL_FORWARD_UNTITLED_ID` | setting | Forward as attachment in the shape Gmail Web builds, with an empty subject and a `Content-ID` on the rfc822 part and on the file attachment of the enclosed inline forward |
| `GOOGLE_GMAIL_CHARSET_MESSAGE_ID` | setting | Message with ISO-8859-15, US-ASCII and invalid UTF-8 text parts and a base64 `message/rfc822` part |
| `GOOGLE_GMAIL_LARGE_BODY_ID` | setting | Message with a 3 MB windows-1252 `text/plain` part, which Gmail keeps behind an `attachmentId`, and a short HTML alternative |
| `GOOGLE_GMAIL_UNNAMED_ATTACHMENT_MESSAGE_ID` | setting | Message with attachments without a filename: three binary parts that Gmail keeps behind an `attachmentId`, and six text parts that it returns inline, four of them converted to UTF-8 from ISO-8859-1, Windows-1252 and UTF-16LE |
| `GOOGLE_GMAIL_CLIENT_FORWARD_OUTLOOK_INLINE_ID` | setting | Inline forward that Outlook Web built: text, HTML with inline images and `test.txt`, without a comment line or a quoted original. Real mail, never recorded |
| `GOOGLE_GMAIL_CLIENT_FORWARD_OUTLOOK_ATTACHED_ID` | setting | Forward as attachment that Outlook Web built: the comment line `Kommentar Outlook Anlage` and the Outlook inline forward as a `message/rfc822` part. Real mail, never recorded |
| `GOOGLE_GMAIL_CLIENT_FORWARD_GMAIL_INLINE_ID` | setting | Inline forward that Gmail Web built: the comment line `Kommentar Gmail inline`, the forwarded original with a `JCL Quelle` subject and an umlaut line, and `test.txt`. Real mail, never recorded |
| `GOOGLE_GMAIL_CLIENT_FORWARD_GMAIL_ATTACHED_ID` | setting | Forward as attachment that Gmail Web built, with an empty subject: the comment line `Kommentar Gmail Anhang` and the Gmail inline forward as a `message/rfc822` part. Real mail, never recorded |
| `GOOGLE_GMAIL_LABEL_ID` | setting | Test label |
| `GOOGLE_GMAIL_DISPOSABLE_MESSAGE_ID` | setting | Message that a write test may delete |
| `GOOGLE_GMAIL_ARCHIVE_MESSAGE_ID` | setting | One message of the two-message archive and label thread |
| `GOOGLE_GMAIL_RECIPIENT` | setting | Second mailbox, controlled by the owner of the test data, that receives the mail of the send check |
| `GOOGLE_CALENDAR_ID` | setting | Test calendar with six prepared `jcl-live` events from 2026-11-09 to 2026-11-15, timed in three zones, across midnight, all-day and multi-day, and a weekly series of six Monday occurrences from 2026-11-09 whose second one is moved |
| `GOOGLE_CALENDAR_EVENT_ID` | setting | Meeting with a 963-byte description, the test user and `GOOGLE_SEED_ATTENDEES` as attendees, an agenda and a handout attachment, and Meet data |
| `GOOGLE_CALENDAR_AGENDA_FILE_ID` | setting | Google Docs agenda attached to that event |
| `GOOGLE_CALENDAR_HANDOUT_URL` | setting | URL-only attachment of that event, ending in `&jcl=a%20b` |
| `GOOGLE_CALENDAR_CONFERENCE_ID` | setting | Meet conference ID of that event |
| `GOOGLE_MEET_CONFERENCE_RECORD` | setting | Past meeting with transcript and recording |
| `GOOGLE_MEET_TRANSCRIPT` | setting | Transcript of that meeting |
| `GOOGLE_MEET_RECORDING` | setting | Recording of that meeting |
| `GOOGLE_MEET_RECORDING_FILE_ID` | setting | Drive file of that recording, also attached to `GOOGLE_CALENDAR_EVENT_ID` |
| `GOOGLE_MEET_NOTES_DOCUMENT_ID` | setting | Gemini notes document of that meeting, attached to `GOOGLE_CALENDAR_EVENT_ID`; in the test tenant Meet writes the transcript as a tab of it, so it is also the transcript's document. Where transcript and notes are separate documents, the Drive export test needs the notes document |
| `GOOGLE_MEET_POLL_EVENT_ID` | setting | Calendar event of the fresh meeting for the poll check |
| `GOOGLE_DRIVE_SHARED_LINK_URL` | setting | Link to a link-shared file. The file in the test tenant has no resource key, so the live checks send the resource-key header only with a made-up key, for a missing file |
| `GOOGLE_DRIVE_SHORTCUT_ID` | setting | Shortcut to that file |
| `GOOGLE_DOCS_TABBED_DOCUMENT_ID` | setting | Document with nested tabs |
| `GOOGLE_DRIVE_STARRED_FILE_ID` | setting | Starred file; its folder also holds exactly one unstarred file named `jcl-live unstarred.txt` |
| `GOOGLE_DRIVE_FOLDER_ID` | setting | Folder with known direct children |
| `GOOGLE_DRIVE_WATCH_FOLDER_ID` | setting | Folder for externally added files |
| `GOOGLE_DRIVE_UPLOAD_FOLDER_ID` | setting | Upload folder created by the app |
| `GOOGLE_DOCS_SCRATCH_DOCUMENT_ID` | setting | Scratch document |
| `GOOGLE_DRIVE_EDIT_FILE_ID` | setting | File that a write test may edit |
| `GOOGLE_DRIVE_DELETE_FILE_ID` | setting | File that a write test may delete |
| `GOOGLE_TEST_USER` | setting | Seed input: the test user |
| `GOOGLE_CLOUD_PROJECT` | setting | Seed input: the test Cloud project |
| `GOOGLE_SEED_ATTENDEES` | setting | Seed input: attendees for seeded events |
| `GOOGLE_LIVE_DESTRUCTIVE` | gate | `true` allows write tests |

#### Prepared Meet data

The Meet live tests read a meeting held on 2026-10-30 in the Meet space of
`GOOGLE_CALENDAR_EVENT_ID`: its conference record
`GOOGLE_MEET_CONFERENCE_RECORD`, its transcript `GOOGLE_MEET_TRANSCRIPT` and
its recording `GOOGLE_MEET_RECORDING`. The window, transcript list, meeting
code and earlier participants checks also expect the conference that began
about 26 minutes earlier in the same space,
`conferenceRecords/6EMiOc40YJH2mjvfx8U6DxIUOBEQAjIGCIoCIAAYAwg`; no variable
names it. Google deletes a conference record 30 days after the
conference ends
([`expireTime`](https://developers.google.com/workspace/meet/api/reference/rest/v2/conferenceRecords)),
and transcript entries after the same 30 days
([Meet artifacts](https://developers.google.com/workspace/meet/api/guides/artifacts)).
The recorded `expireTime` is 2026-11-29T16:54:56Z for the earlier record and
2026-11-29T17:19:37Z for `GOOGLE_MEET_CONFERENCE_RECORD`. From then on, the
Meet live tests that read them are skipped with a reason instead of failing.

Those tests carry `LiveMeet.prepared!/1` from
`apps/jido_connect_google_meet/test/support/live_meet.ex` after their `env!/1`
tag. The tag lists the prepared items a test reads: the variables
`GOOGLE_MEET_CONFERENCE_RECORD` and `GOOGLE_MEET_TRANSCRIPT`, and
`:earlier_conference_record` for the earlier record, whose name is
`@earlier_conference_record` in `LiveMeet`. Like `env!/1`, the tag runs when
the test file compiles, before ExUnit knows the test's name and describe. It
therefore asks Google in every run with an include filter, because each one
overrides the `:live_smoke` exclude for the tests it selects:
`--only live_smoke`, `--include live_smoke`, `--only test:"..."`,
`--only describe:"..."` or a location such as `mix test <file>:<line>`. It
asks once per record or transcript and VM, so such a run costs at most one
request per item and value. With `GOOGLE_ACCESS_TOKEN` it sends
`conferenceRecords.get` with `fields=name` for `GOOGLE_MEET_CONFERENCE_RECORD`
and the earlier record, and one page of `transcripts.entries.list` without
entry text for `GOOGLE_MEET_TRANSCRIPT`. A plain `mix test` has no include
filter and asks nothing. Two answers count as deleted data:

- 404 with `error.status` `NOT_FOUND`, Google's answer for a missing
  transcript under a living record, recorded with the ErrorInfo reason
  `TRANSCRIPT_NOT_FOUND` as `transcript_entries_not_found`;
- 403 with `error.status` `PERMISSION_DENIED`, no ErrorInfo reason and the
  message `Permission denied on resource Conference (or it might not exist)`,
  Google's answer for a conference record that does not exist.

The answer for the prepared record cannot be seen before Google deletes it,
so the 403 is derived. On 2026-11-06 Google gave it for a well-formed record
ID that names no conference visible to the test user, both for the record and
for the transcript entries under it; `live_prepared_data_test.exs` records it
as `conference_record_unknown` and `transcript_entries_unknown_record`. A
deleted record no longer exists, so its tests get the same answer. Every
other answer leaves the test to run and fail: success, 401, a 403 with the
ErrorInfo reason `ACCESS_TOKEN_SCOPE_INSUFFICIENT` (recorded as
`conference_record_scope_insufficient`), 400, 5xx and transport errors. The
tag checks the items in the given order and skips on the first one whose data
is gone. The skip reason names the variable, or the earlier record as such,
the preparation date, the status, Google's `error.status` and the ErrorInfo
reason or else Google's message, and the run prints it like an `env!/1` skip:

```text
live_smoke skip test/jido_connect/google/meet/live_smoke_test.exs:72: GOOGLE_MEET_CONFERENCE_RECORD, prepared on 2026-10-30, has expired: Google answered 403 PERMISSION_DENIED "Permission denied on resource Conference (or it might not exist)"; see "Prepared Meet data" in docs/live_smoke_tests.md
live_smoke skip test/jido_connect/google/meet/live_smoke_test.exs:152: conferenceRecords/6EMiOc40YJH2mjvfx8U6DxIUOBEQAjIGCIoCIAAYAwg, the earlier conference prepared on 2026-10-30 in the space of GOOGLE_MEET_CONFERENCE_RECORD, has expired: Google answered 403 PERMISSION_DENIED "Permission denied on resource Conference (or it might not exist)"; see "Prepared Meet data" in docs/live_smoke_tests.md
```

Neither answer is unique to expired data. Google gives the 403 also for a
record that exists but that the account of `GOOGLE_ACCESS_TOKEN` cannot see,
and the 404 also for a transcript ID that never existed, as in
`transcript_entries_not_found`. A skip before 2026-11-29 therefore points at
the configuration, such as a wrong ID or a token of another account; the skip
line prints Google's answer for the check that skipped. The 404 rule still
holds for `GOOGLE_MEET_TRANSCRIPT`: a transcript that the variable names and
that no longer exists is gone data, and Google deletes transcript entries 30
days after the conference ends.

Another Meet live test that reads prepared data adopts the tag with the
prepared items it reads. Anything under the conference record, such as a
recording or participants, counts as `GOOGLE_MEET_CONFERENCE_RECORD`; other
items fail when the file compiles. A test that also expects the earlier
record lists `:earlier_conference_record` after
`GOOGLE_MEET_CONFERENCE_RECORD`: Google deletes the earlier record about 25
minutes before the prepared one, which skips the test in between, and once
both are gone the skip names the variable. A test without prepared data stays
untagged.

```elixir
alias Jido.Connect.Google.Meet.TestSupport.LiveMeet
require LiveMeet

@tag env!(["GOOGLE_ACCESS_TOKEN", "GOOGLE_MEET_CONFERENCE_RECORD"])
@tag LiveMeet.prepared!(["GOOGLE_MEET_CONFERENCE_RECORD"])
test "lists the participants of the prepared conference", %{env: env} do
  # ...
end
```

Fresh data needs a person who holds a new meeting.
`~/.config/jido_connect/live/seed/google/meeting-wizard.sh` walks through a
recorded, transcribed meeting with Gemini notes in the Meet space of
`GOOGLE_CALENDAR_EVENT_ID`. Its last stage, `seed.py meet-collect`, rewrites
`GOOGLE_MEET_CONFERENCE_RECORD`, `GOOGLE_MEET_TRANSCRIPT` and
`GOOGLE_MEET_RECORDING`; set `GOOGLE_MEET_RECORDING_FILE_ID` and
`GOOGLE_MEET_NOTES_DOCUMENT_ID` by hand. The wizard walks through one
meeting, but four checks assume two conferences in the prepared space: the
window and transcript list checks in the Meet `live_smoke_test.exs` and the
earlier participants check in `participants_live_smoke_test.exs` expect
exactly two in the window, and the meeting code check in
`live_meeting_lookup_test.exs` at least two in the space
(`assert length(names) >= 2`). With one fresh conference these checks fail.
Fresh data therefore needs a second, earlier conference in the same space and
window, or these checks change with it. With the new meetings, change the
preparation date `@prepared_on` and the earlier record
`@earlier_conference_record` in `LiveMeet`, the window
`@prepared_window_start` and `@prepared_window_end` in the Meet
`live_smoke_test.exs`, and the occurrence `@scheduled_start` and
`@scheduled_end` in the Meet `live_meeting_lookup_test.exs` and the Calendar
`live_meet_association_test.exs`. Then record the Meet live tests again with
`JIDO_CONNECT_RECORD=1` and adjust the offline tests that pin recorded
counts: the check in `client_test.exs` that the second page of
`transcript_entries` is the last one, and the two conferences in the window
that the Meet live checks and the poll tests in `transcript_poller_test.exs`
expect.

### Slack

| Variable | Kind | Meaning |
| --- | --- | --- |
| `SLACK_BOT_TOKEN` | credential | Bot token of the test app |
| `SLACK_SIGNING_SECRET` | credential | Signing secret of the test app |
| `SLACK_USER_TOKEN` | credential | User token of the test user |
| `SLACK_CONFIG_TOKEN` | credential | App configuration token of the test workspace, for `apps.manifest.validate`; expires 12 hours after it is issued |
| `SLACK_CONFIG_REFRESH_TOKEN` | credential | Refresh token of that configuration token; `tooling.tokens.rotate` replaces both |
| `SLACK_PUBLIC_CHANNEL_ID` | setting | Public channel |
| `SLACK_PRIVATE_CHANNEL_ID` | setting | Private channel |
| `SLACK_DM_CHANNEL_ID` | setting | Direct message |
| `SLACK_MPIM_CHANNEL_ID` | setting | Group direct message |
| `SLACK_NO_ACCESS_CHANNEL_ID` | setting | Channel the bot is not in |
| `SLACK_THREAD_TS` | setting | Thread with replies over more than one page |
| `SLACK_PRIVATE_THREAD_TS` | setting | Thread with seven bot replies in `SLACK_PRIVATE_CHANNEL_ID` |
| `SLACK_DM_THREAD_TS` | setting | Thread with seven bot replies in `SLACK_DM_CHANNEL_ID` |
| `SLACK_MPIM_THREAD_TS` | setting | Thread with seven bot replies in `SLACK_MPIM_CHANNEL_ID` |
| `SLACK_SECOND_USER_ID` | setting | Second human user |
| `SLACK_CAPTURE_DIR` | setting | Capture directory of the demo host |
| `SLACK_APP_ID` | setting | ID of the test app |
| `JIDO_PUBLIC_URL` | setting | Public base URL of the demo host, the tunnel of `mix jido.connect.ngrok`; the request URLs of the validated manifests start with it |
| `SLACK_LIVE_DESTRUCTIVE` | gate | `true` allows write tests |

The manifest check in `app_manifest_live_smoke_test.exs` runs
`mix jido.connect.slack.app.manifest_url` for `JIDO_PUBLIC_URL` and has
Slack's `apps.manifest.validate` check the default manifest, the manifest
with events and interactivity, and that one with the user view. It passes no
`app_id`, so no app is created, changed or installed, and it needs no running
tunnel. When Slack answers `token_expired`, renew the pair with
`tooling.tokens.rotate` and `SLACK_CONFIG_REFRESH_TOKEN` and store both new
values at once, since the old refresh token stops working; the tests do not
rotate.

### Jira

| Variable | Kind | Meaning |
| --- | --- | --- |
| `JIRA_SITE` | setting | Site URL, `https://<site>.atlassian.net` |
| `JIRA_EMAIL` | setting | Test user for API token auth |
| `JIRA_API_TOKEN` | credential | API token of the test user |
| `JIRA_PROJECT_KEY` | setting | Test project |
| `JIRA_ISSUE_KEY` | setting | Test issue |
| `JIRA_ISSUE_ID` | setting | Numeric ID of the test issue |
| `JIRA_WEBHOOK_SECRET` | credential | Secret of the registered webhook |
| `JIRA_CAPTURE_DIR` | setting | Capture directory of the demo host |
| `SEED_ADMIN_EMAIL` | setting | Seed input: site administrator |
| `SEED_ADMIN_API_TOKEN` | credential | Seed input: API token of the site administrator |
| `JIRA_LIVE_DESTRUCTIVE` | gate | `true` allows write tests |

### Tempo

| Variable | Kind | Meaning |
| --- | --- | --- |
| `TEMPO_API_TOKEN` | credential | Tempo API token of the test user |
| `TEMPO_OAUTH_CLIENT_ID` | setting | Tempo OAuth application |
| `TEMPO_OAUTH_CLIENT_SECRET` | credential | Tempo OAuth client secret |
| `TEMPO_OAUTH_REDIRECT_URI` | setting | Redirect URI on the demo host |
| `TEMPO_OAUTH_ACCESS_TOKEN` | credential | OAuth access token |
| `TEMPO_OAUTH_REFRESH_TOKEN` | credential | OAuth refresh token; each refresh replaces it |
| `TEMPO_OAUTH_ACCESS_TOKEN_EXPIRES_AT` | setting | Expiry of the stored access token |
| `TEMPO_OAUTH_CODE` | credential | Authorization code of one browser authorization |
| `TEMPO_OAUTH_TOKEN_FILE` | setting | Absolute path of a new or empty file outside the repository that receives the token pair of the exchange test |
| `SEED_TEMPO_API_TOKEN` | credential | Seed input: Tempo API token with admin rights |
| `TEMPO_API_ORIGIN` | setting | Tempo API origin |
| `TEMPO_ACCOUNT_ID` | setting | Tempo account linked to the test project |
| `TEMPO_JIRA_ISSUE_ID` | setting | Jira issue for worklogs |
| `TEMPO_JIRA_PROJECT_ID` | setting | Jira project for worklogs |
| `TEMPO_WORK_ATTRIBUTES` | setting | `required` or `optional`: the mode in which the test work attributes exist for this run; unset when they do not exist |
| `TEMPO_LIVE_DESTRUCTIVE` | gate | `true` allows tests that create worklogs |

The Tempo exchange test runs only when `TEMPO_OAUTH_CODE` is set, taken from
the `code` parameter of the redirect after one browser authorization. One run
consumes the code and rotates the pair: it exchanges the code for a new pair,
refreshes that pair once and writes each pair at once to
`TEMPO_OAUTH_TOKEN_FILE`, with mode 0600, as `TEMPO_OAUTH_ACCESS_TOKEN`,
`TEMPO_OAUTH_REFRESH_TOKEN` and `TEMPO_OAUTH_ACCESS_TOKEN_EXPIRES_AT` lines.
Put that file in a directory only you can write, such as
`~/.config/jido_connect/live`, and name it with an absolute path; the test
fails before the exchange when the path is relative or inside the repository.
The file then holds the only valid refresh token of that authorization; copy
its lines to `atlassian.env` and the password manager. The test does not use
the stored `TEMPO_OAUTH_REFRESH_TOKEN`. With recording on, it writes the two
token responses to `oauth_exchange.json` and `oauth_refresh.json`, with the
token fields redacted, and deletes a file that still holds a token or the
code.

The Tempo own worklog checks are the five tests that record `worklogs_own`,
`worklogs_own_small_page`, `worklogs_own_day`, `worklogs_own_empty` and
`worklogs_own_jira`. They rely only on the test user's seeded worklogs.
Each read except the empty July range is compared with a direct Tempo read,
so further own worklogs from August to October do not break them; the July
read must return no worklogs. Three recordings also hold worklogs that the
test user created on JCL-2 on 2026-11-02, outside the seeded data:
`worklogs_own.2.json` and `worklogs_own_day.json` hold 79166, booked at
00:30 Europe/Berlin on 2026-10-31 with a description of 778 bytes, and
`worklogs_own_jira.json` holds 79167 and 79168, created through Jira's
worklog API without a comment and with an empty one. Re-recording these
files needs those worklogs, since the offline tests pin their IDs and
shapes. An empty answer names the account only in links, so the sanitizer
cannot learn the account ID from it: the empty range is recorded after a
seeded day, and the October 31 test stops in recording mode when that day
has no worklog.

The Tempo worklog create in `live_smoke_test.exs` is the Tempo check that
creates data outside a work-attribute window; the attribute booking checks
below create data inside one. With
`TEMPO_LIVE_DESTRUCTIVE=true` it creates one worklog of the test user on
`TEMPO_JIRA_ISSUE_ID` on 2026-10-29, in the open October period, reads it
back and books the same input into the approved August period, which Tempo
rejects with a 403. Each run leaves one worklog on 2026-10-29; the package
cannot delete it, so it stays until the test data is cleaned up, and a
re-recording of `worklogs_own` holds it. The test records the create, the
read-back and the rejection in one session, `worklog_create.json` to `.3`,
so the sanitizer learns the account ID from the created worklog's author
before it writes the read-back path. 79177 is the worklog of that
recording. A second write-gated test posts a start time of `25:00:00` into
the approved period for Tempo's 400, `worklog_create_invalid_time.json`;
it cannot create a worklog. If Tempo accepted a booking into the approved
period, either test stops at once and names the new ID.

The Tempo period checks rely only on the seeded approvals of the test user:
August 2026 `APPROVED`, September `IN_REVIEW` and October `OPEN`. Further
worklogs in October do not change them. Each status and its time are
compared with a direct approval read of the same period by the same user.
`period_bookability.json` holds the periods of August 15 to October 15,
2026, and `.2` to `.4` the three approvals; the sanitizer numbers the
reviewer of August first, so the test user is `account-2` there.
`timesheet_approval.json` holds the October approval and `.2` Tempo's 400
for a range across two periods. That 400 names no account in its body, so
it is recorded after the October approval, from whose `user` the sanitizer
learns the account ID before it writes the request path.

The Tempo booking lookup checks are in `booking_lookup_live_smoke_test.exs`.
The account check relies on the seeded accounts alone: JCL-PROJECT
(`TEMPO_ACCOUNT_ID`, the default link), JCL-SECONDARY and the closed
JCL-CLOSED, linked to `TEMPO_JIRA_PROJECT_ID`, and the global JCL-GLOBAL.
The work attribute checks need the five test attributes `_JclPhase_`,
`_JclBillable_`, `_JclHours_`, `_JclAccount_` and `_JclNote_`, which exist
on the shared site only around a run, since every user's time-entry form
shows them.
`~/.config/jido_connect/live/seed/atlassian/tempo_attributes.py up` creates
them, required unless `--optional`, with the free-text `_JclNote_` optional
in both modes, and gives the seeded worklog of October 1, 2026 a value for
each; `down` deletes them and their values.
Those checks run only with `TEMPO_WORK_ATTRIBUTES` set to the mode of the
run, `required` or `optional`, and are skipped without it. The attribute
check compares every test attribute's required flag with that mode and
names its recording after it, `work_attributes_required` or
`work_attributes_optional`. The value check records `work_attribute_values`
in the optional mode only, so a required run never overwrites it. Tempo
assigns new stored values each time `up` creates `_JclPhase_`, and the
offline tests match the stored value in `work_attribute_values` against
`work_attributes_optional`: record those two in the same optional run.
`work_attributes_required` needs a required run of its own.

While the test attributes exist, run only the booking lookup checks and,
in a required run, the attribute booking checks, and run `down` at once
after them, also when a check fails or the run is interrupted. In a
required run Tempo lists four of them as required, for the whole site. The
two write checks of `live_smoke_test.exs`, the worklog create and the
invalid start time, send no attribute values; how Tempo answers them inside
a required window was not tried, so each fails before it sends anything
while `TEMPO_WORK_ATTRIBUTES` is set. Run the rest of the Tempo suite after
`down`, with `TEMPO_WORK_ATTRIBUTES` unset.

The Tempo attribute booking checks are in
`attribute_booking_live_smoke_test.exs`. They need
`TEMPO_WORK_ATTRIBUTES=required` and `TEMPO_LIVE_DESTRUCTIVE=true`, and each
fails before its first write unless Tempo lists `_JclPhase_`,
`_JclBillable_`, `_JclHours_` and `_JclAccount_` as required, so they never
write outside a required window. Run the file inside one, as a command of
its own:

```sh
MIX_ENV=test TEMPO_WORK_ATTRIBUTES=required TEMPO_LIVE_DESTRUCTIVE=true \
  mix do --app jido_connect_tempo test --include live_smoke \
  test/jido_connect/tempo/attribute_booking_live_smoke_test.exs
```

Every booking carries a value for each of the four, read first through
`tempo.work_attribute.list` and `tempo.account.list_for_project`: the
stored value of the label build, `"true"`, `"1.5"` and the key of
`TEMPO_ACCOUNT_ID`. Each run leaves three worklogs of the test user on
`TEMPO_JIRA_ISSUE_ID` on 2026-10-27, in the open October period: a seed
worklog of 60 seconds, which the first check posts through the client
transport, outside the actions and before the recording starts, with
`remainingEstimateSeconds` 7200; the booking of 1800 seconds through
`prepare/4` and `commit/4` with the API token; and the booking of 900
seconds with the OAuth access token. The OAuth check takes its
connection's labels from the `scope` recorded in `oauth_refresh.json`.
Before it writes, it fails unless that scope grants `worklogs:manage` and
not `write`, and unless `TEMPO_OAUTH_ACCESS_TOKEN_EXPIRES_AT` lies within
10 seconds of that response's `date` plus its `expires_in`, which shows
that the recorded response issued the stored pair. A pair rotated without
recording therefore stops the check with a message that names the
variable, not with Tempo's 403. A further check books the same values with
the unknown account key `JCL-UNKNOWN`, which Tempo rejects with a 404; if
Tempo accepted it, the check would stop at once and name the new ID. Each
run also changes the Jira remaining estimate of `TEMPO_JIRA_ISSUE_ID`: the
seed sets it to 7200 seconds, and each booking lowers it by its time, which
the first check reads from Jira and expects.

The first check waits for Jira after the seed and after its booking, the
OAuth check after its booking, each time until Jira lists the new worklog,
at most 30 reads 2 seconds apart; the file allows each check 5 minutes.
Since the OAuth check ends only once Jira lists its booking, the first
check starts with no worklog of the run still on its way to Jira, in
whichever order ExUnit runs the checks. Each check prints a worklog's ID as
soon as Tempo returns it, before it waits.
The recording run on 2026-11-06 created 79266 (seed), 79267 and 79268; the
proof run after it created 79269, 79270 and 79271.

The checks record `worklog_create_attributes`,
`worklog_create_invalid_attribute` and `worklog_create_oauth`, each with
the test user's account ID as `accounts:`, and the read-backs of the two
bookings as `worklog_create_attributes.2.json` and
`worklog_create_oauth.2.json`, through `LiveTempo.site_data/2`; none of
them carries `"transformed": true`. The offline tests pin the stored value
of `_JclPhase_` that Tempo assigned in that window, as sent in the
recorded bookings. A re-recording in a later window gets another stored
value, so the `@build` value of `worklog_create_test.exs` and
`create_worklog_action_test.exs` changes with it.

The site is shared with real users, and Tempo returns their data in the
same responses: every work attribute of the site and every global account
with each project's links. The recordings leave it out with the
`:transform` option that `LiveTempo.site_data/2` in
`apps/jido_connect_tempo/test/support/live_tempo.ex` builds: other
attributes keep Tempo's structure, with a neutral key `_Other1_` and
onward, name, link, stored values and labels, and their type and required
flag; links of other accounts are left out with `metadata.count` adjusted,
reads of those accounts are not recorded, and worklog values of other
attributes are left out. The live assertions check only the test data and
pass whatever else the site holds.

Of the current recordings, `work_attributes_required.json`,
`work_attributes_optional.json` and `accounts_for_project.json` were
changed this way. They carry `"transformed": true`, added by hand after the
recording; a re-recording writes it itself. The account details
`accounts_for_project.2.json` to `.5.json` are those of test accounts,
which the transform keeps as sent. `work_attribute_values.json` carries no
marker: its recorded `content-length` matches its body once the
sanitizer's replacements of the account ID and the site host are counted
back, so the transform removed no value there.

### Confluence

| Variable | Kind | Meaning |
| --- | --- | --- |
| `CONFLUENCE_SITE` | setting | Site URL, `https://<site>.atlassian.net` |
| `CONFLUENCE_EMAIL` | setting | Test user for API token auth |
| `CONFLUENCE_API_TOKEN` | credential | API token of the test user |
| `CONFLUENCE_PAGE_ID` | setting | Plain page |
| `CONFLUENCE_RICH_PAGE_ID` | setting | Page with images, a macro and an inline comment |
| `CONFLUENCE_RESTRICTED_PAGE_ID` | setting | Page the test user cannot read |
| `CONFLUENCE_LIVE_DESTRUCTIVE` | gate | `true` allows write tests |

A build ticket that needs another variable adds it here and to the variable

## Provider notes

The packages that load the harness are `jido_connect_gmail`,
`jido_connect_google_calendar`, `jido_connect_google_meet`,
`jido_connect_google_drive`, `jido_connect_google_docs`, `jido_connect_slack`,
`jido_connect_jira`, `jido_connect_confluence` and `jido_connect_tempo`. Each
has a `live_smoke_test.exs` with at least one read-only test.

The env files hold plain `NAME=value` lines, so `set -a` exports them to
`mix`. Google access tokens expire after an hour and are not stored: mint
`GOOGLE_ACCESS_TOKEN` and `GOOGLE_GMAIL_METADATA_ACCESS_TOKEN` from the refresh
tokens before each run. The Docs and Drive checks of a Drive-only grant also
need `GOOGLE_DRIVE_ONLY_ACCESS_TOKEN`. A refresh of `GOOGLE_REFRESH_TOKEN`
that adds `scope=https://www.googleapis.com/auth/drive` to the token request
returns a token narrowed to that scope; Google reports the granted scopes in
the `scope` field of the response, and a run uses the token only when that
field is exactly the Drive scope. These checks, in
`apps/jido_connect_google_docs/test/jido_connect/google/docs/live_smoke_test.exs`
and `apps/jido_connect_google_drive/test/jido_connect/google/drive/live_tabbed_export_test.exs`,
ask Google's `tokeninfo` endpoint again before they read, so a run with a
broader token fails.


```

Gmail keeps its capability checks beside `live_smoke_test.exs` in
`apps/jido_connect_gmail/test/jido_connect/gmail/`, one file per capability
family: `discovery_live_smoke_test.exs` for inbox and archive discovery and
for the metadata reads of a message and its thread under the
`gmail.metadata` grant, recorded as `message_metadata_subject` and
`thread_metadata_subject`,
`content_live_smoke_test.exs` for message and thread content and forwards,
`content_client_forwards_live_smoke_test.exs` for forwards that Outlook Web
and Gmail Web built, `attachments_live_smoke_test.exs` for attachment content,
`history_live_smoke_test.exs` for the new-message and change polls and Trash,
`labels_live_smoke_test.exs` for labels and archiving, and
`send_live_smoke_test.exs` for sending mail and drafts. Their shared helpers
are in `test/support/live_gmail.ex`, which the package's `test_helper.exs`
loads.

The four client forwards in `GOOGLE_GMAIL_CLIENT_FORWARD_*` are real mail
with a person's name, signature, addresses and images. Their check reads them
through the content and attachment actions and records nothing, also when the
run sets `JIDO_CONNECT_RECORD=1`, because it never calls `LiveGmail.record/1`,
the only way a live test records. It looks at text only for the marker lines,
the `JCL Quelle` subject and signs of wrong decoding, and its assertions name
the forward and the check instead of printing text. The shapes these forwards
showed that no other recording had are rebuilt with synthetic content in the
messages of `GOOGLE_GMAIL_FORWARD_RELATED_ID` and
`GOOGLE_GMAIL_FORWARD_UNTITLED_ID`, which `content_live_smoke_test.exs`
records as `message_full_forward_related` and `message_full_forward_untitled`
with the attachment bytes of each.

The send check is the one Gmail check that mails another mailbox. With
`GOOGLE_LIVE_DESTRUCTIVE=true` it sends a new mail and a reply in the same
thread to `GOOGLE_GMAIL_RECIPIENT`, so each run puts two mails there, and
those copies stay. Keep such runs few. The draft check addresses its draft to
the same mailbox and sends nothing. Subjects and bodies hold umlauts. Both
tests read back what Gmail stores in `format=raw`, outside the connector and
the recorder, and the subject and body through
`google.gmail.message.content.get`, and delete the sender's copies, the draft
and an inserted message when they exit. Gmail answered 500 to deleting a
message right after sending it, so `LiveGmail.delete_message!/2` and
`LiveGmail.delete_draft!/2` retry transient failures. The recordings
`message_send.json`, `message_send_reply.json`, `draft_create.json` and
`draft_update.json` each hold the answer to one write. The content reads
record as `message_content_sent` and `message_content_draft`, which no offline
test uses and which are not committed.

The Meet checks read meeting data prepared on 2026-10-30, which Google
deletes on 2026-11-29; "Prepared Meet data" under Google Workspace says how
they are skipped from then on. Google's page token for participants encodes
the next participant's user ID in Base64, so `participants.json` keeps the
placeholder `nextPageToken-1`.

### Capturing deliveries

The demo host captures verified Slack and Jira deliveries for
`LiveSmoke.write_capture!/4`; `dev/demo/README.md` describes the capture
directories and their limits. Point the Slack event and interactivity
request URLs and the Jira webhook URL at the tunnel of
`mix jido.connect.ngrok`.

A capture directory holds 20 files. A checklist with more deliveries, such
as the edit and deletion checks of `message_ingress_live_smoke_test.exs`,
fills it during the run: move the full batch into a subdirectory, such as
`batch-1/`, and the next deliveries take the free slots. The Slack live tests
read `slack-*.json` of `SLACK_CAPTURE_DIR` and its subdirectories by route
and payload, and tell a retry apart from its first delivery by `event_id`;
the Jira live tests read `jira-*.json` the same way.

Recording never replaces a fixture. The provider helpers keep setup calls out
of the fixtures with a transform that skips every response. A poll that the
Calendar tests retry refuses to start while a fixture of its name exists and
removes only the files of its earlier attempts before it records again
(`LiveCalendar.record_attempt/2`).
