defmodule Jido.Connect.Gmail.LiveSmokeTest do
  @moduledoc """
  Live smoke checks against the Google Workspace test account.

      mix test --only live_smoke

  See `docs/live_smoke_tests.md` for the variables and the recording mode.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect.Gmail.Client

  @tag env!(["GOOGLE_ACCESS_TOKEN"])
  test "reads the mailbox profile", %{env: env} do
    LiveSmoke.record({:jido_connect_google, :google_req_options}, :gmail, "profile")

    assert {:ok, profile} = Client.get_profile(%{}, env["GOOGLE_ACCESS_TOKEN"])
    assert is_map(profile)
  end
end
