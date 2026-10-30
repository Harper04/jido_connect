defmodule Jido.Connect.Google.Calendar.LiveSmokeTest do
  @moduledoc """
  Live smoke checks against the Google Workspace test account.

      mix test --only live_smoke

  See `docs/live_smoke_tests.md` for the variables and the recording mode.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect.Google.Calendar.Client

  @tag env!(["GOOGLE_ACCESS_TOKEN"])
  test "lists one page of the calendar list", %{env: env} do
    LiveSmoke.record(
      {:jido_connect_google, :google_req_options},
      :google_calendar,
      "calendar_list"
    )

    assert {:ok, result} = Client.list_calendars(%{page_size: 1}, env["GOOGLE_ACCESS_TOKEN"])
    assert is_map(result)
  end
end
