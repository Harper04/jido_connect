defmodule Jido.Connect.Google.Calendar.LiveSmokeTest do
  @moduledoc """
  Live smoke checks against the Google Workspace test account.

      mix test --only live_smoke

  See `docs/live_smoke_tests.md` for the variables and the recording mode.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect.Google.Calendar.Client

  @tag env!(["GOOGLE_ACCESS_TOKEN", "GOOGLE_CALENDAR_ID"])
  test "lists one page of events on the test calendar", %{env: env} do
    LiveSmoke.record({:jido_connect_google, :google_req_options}, :google_calendar, "events")

    assert {:ok, result} =
             Client.list_events(
               %{calendar_id: env["GOOGLE_CALENDAR_ID"], page_size: 1},
               env["GOOGLE_ACCESS_TOKEN"]
             )

    assert is_map(result)
  end
end
