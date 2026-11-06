defmodule Jido.Connect.Google.Calendar.FixtureTest do
  use ExUnit.Case, async: true

  alias Jido.Connect.Google.Calendar.Normalizer
  alias Jido.Connect.Google.TestSupport.ConnectorContracts
  alias Jido.Connect.TestSupport.LiveSmoke

  test "normalizes common Google Calendar event fixture" do
    # events.get of the prepared meeting, recorded from the test account.
    payload = LiveSmoke.fixture!(:google_calendar, "event_get")

    assert {:ok, event} = Normalizer.event(payload, calendar_id: "primary")
    assert event.event_id == "ndvt3dobe2f7dac8l940ha6iug"
    assert event.calendar_id == "primary"
    assert event.summary == "jcl-live meeting with transcript"
    assert event.start == "2026-10-30T17:55:00+01:00"
    assert event.end == "2026-10-30T18:40:00+01:00"

    assert [
             %{
               email: "person-1@example.com",
               response_status: "needsAction",
               organizer?: true,
               self?: true
             },
             %{email: "person-2@example.com", response_status: "needsAction", organizer?: false}
           ] = event.attendees
  end

  test "normalizes edge Google Calendar freebusy fixture" do
    payload = fixture!("freebusy_edge.json")

    assert {:ok, free_busy} = Normalizer.free_busy(payload)
    assert [%{calendar_id: "primary", start: "2026-05-06T09:00:00Z"}] = free_busy.busy

    assert %{
             target_type: :calendar,
             target_id: "missing@example.com",
             domain: "global",
             reason: "notFound"
           } in free_busy.errors

    assert %{
             target_type: :group,
             target_id: "team@example.com",
             domain: "global",
             reason: "groupTooBig"
           } in free_busy.errors
  end

  defp fixture!(name) do
    ConnectorContracts.google_fixture!(:google_calendar, name, __DIR__)
  end
end
