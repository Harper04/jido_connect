defmodule Jido.Connect.Google.Meet.LiveSmokeTest do
  @moduledoc """
  Live smoke checks against the Google Workspace test account.

      mix test --only live_smoke

  See `docs/live_smoke_tests.md` for the variables and the recording mode.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect.Google.Meet.Client

  @tag env!(["GOOGLE_ACCESS_TOKEN"])
  test "lists one page of conference records", %{env: env} do
    LiveSmoke.record(
      {:jido_connect_google, :google_req_options},
      :google_meet,
      "conference_records"
    )

    assert {:ok, result} =
             Client.list_conference_records(%{page_size: 1}, env["GOOGLE_ACCESS_TOKEN"])

    assert is_map(result)
  end
end
