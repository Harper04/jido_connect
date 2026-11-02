defmodule Jido.Connect.Google.Calendar.LiveMeetAssociationTest do
  @moduledoc """
  Live check of what the prepared meeting's event hands to the Meet and Drive
  live tests.

      mix test --only live_smoke

  `live_event_read_test.exs` checks that the event's
  `conference_data["conferenceId"]` is `GOOGLE_CALENDAR_CONFERENCE_ID`, the
  meeting code by which the Meet live tests look up the conference record.
  This test checks the rest of that chain on the Calendar side: the scheduled
  occurrence, which the Meet lookup uses as its `start_time` window, and the
  attached recording and notes, which the Drive live tests download and
  export. The packages do not depend on each other, so the variables in
  `docs/live_smoke_tests.md` carry the IDs between them.

  The response has the shape of `event_get.json`, so this test records nothing.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect.Google.Calendar.TestSupport.LiveCalendar

  # The scheduled occurrence of the prepared meeting. The Meet record lookup
  # in jido_connect_google_meet uses the same times as its start_time window.
  @scheduled_start "2026-10-30T17:55:00+01:00"
  @scheduled_end "2026-10-30T18:40:00+01:00"

  @recording_mime_type "video/mp4"
  @document_mime_type "application/vnd.google-apps.document"

  @tag env!([
         "GOOGLE_ACCESS_TOKEN",
         "GOOGLE_CALENDAR_ID",
         "GOOGLE_CALENDAR_EVENT_ID",
         "GOOGLE_MEET_RECORDING_FILE_ID",
         "GOOGLE_MEET_NOTES_DOCUMENT_ID"
       ])
  test "the prepared meeting carries its occurrence and its Meet recording and notes", %{
    env: env
  } do
    assert {:ok, %{event: event}} =
             LiveCalendar.invoke(
               "google.calendar.event.get",
               %{
                 calendar_id: env["GOOGLE_CALENDAR_ID"],
                 event_id: env["GOOGLE_CALENDAR_EVENT_ID"]
               },
               env["GOOGLE_ACCESS_TOKEN"],
               [LiveCalendar.events_readonly_scope()]
             )

    assert {event.start, event.end} == {@scheduled_start, @scheduled_end}

    assert attachment!(event, env["GOOGLE_MEET_RECORDING_FILE_ID"])["mimeType"] ==
             @recording_mime_type

    assert attachment!(event, env["GOOGLE_MEET_NOTES_DOCUMENT_ID"])["mimeType"] ==
             @document_mime_type
  end

  # The attachment with Drive file `file_id`, by ID only: titles depend on the
  # locale of the meeting organizer.
  defp attachment!(event, file_id) do
    assert [attachment] = Enum.filter(event.attachments, &(&1["fileId"] == file_id))
    attachment
  end
end
