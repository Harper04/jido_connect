defmodule Jido.Connect.Slack.LiveSmokeTest do
  @moduledoc """
  Live smoke checks against the Slack test workspace.

      mix test --only live_smoke

  See `docs/live_smoke_tests.md` for the variables, the recording mode and
  the capture mode of the demo host.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect.Slack.{Client, Webhook}

  @tag env!(["SLACK_BOT_TOKEN"])
  test "auth.test accepts the bot token", %{env: env} do
    LiveSmoke.record({:jido_connect_slack, :slack_req_options}, :slack, "auth_test")

    assert {:ok, identity} = Client.auth_test(env["SLACK_BOT_TOKEN"])
    assert is_map(identity)
  end

  @tag env!(["SLACK_SIGNING_SECRET", "SLACK_CAPTURE_DIR"])
  test "the newest captured event replays before and after sanitizing", %{env: env} do
    path =
      env["SLACK_CAPTURE_DIR"]
      |> Path.join("slack-events-*.json")
      |> Path.wildcard()
      |> Enum.max(fn -> flunk("no slack-events-*.json capture in SLACK_CAPTURE_DIR") end)

    assert {:ok, _delivery} =
             LiveSmoke.replay(path, webhook: Webhook, secret: env["SLACK_SIGNING_SECRET"])

    assert {:ok, _delivery} =
             path
             |> LiveSmoke.sanitize_capture()
             |> LiveSmoke.replay(webhook: Webhook)
  end
end
