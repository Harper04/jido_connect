defmodule Jido.Connect.Google.Drive.LiveSmokeTest do
  @moduledoc """
  Live smoke checks against the Google Workspace test account.

      mix test --only live_smoke

  See `docs/live_smoke_tests.md` for the variables and the recording mode.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect.Google.Drive.Client

  @tag env!(["GOOGLE_ACCESS_TOKEN"])
  test "reads the Drive about resource", %{env: env} do
    LiveSmoke.record({:jido_connect_google, :google_req_options}, :google_drive, "about")

    assert {:ok, about} = Client.get_about(%{}, env["GOOGLE_ACCESS_TOKEN"])
    assert is_map(about)
  end
end
