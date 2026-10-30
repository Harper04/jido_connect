defmodule Jido.Connect.Jira.LiveSmokeTest do
  @moduledoc """
  Live smoke checks against the Atlassian Cloud test site.

      mix test --only live_smoke

  See `docs/live_smoke_tests.md` for the variables and the recording mode.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect.Jira.{Client, TestRuntime, Webhook}

  @tag env!(["JIRA_SITE", "JIRA_EMAIL", "JIRA_API_TOKEN", "JIRA_PROJECT_KEY"])
  test "reads the test project", %{env: env} do
    LiveSmoke.record({:jido_connect_jira, :jira_req_options}, :jira, "project")

    assert {:ok, request} =
             [site: env["JIRA_SITE"], email: env["JIRA_EMAIL"], api_token: env["JIRA_API_TOKEN"]]
             |> TestRuntime.build()
             |> Client.request_context()

    assert {:ok, project} = Client.get_project(env["JIRA_PROJECT_KEY"], request)
    assert is_map(project)
  end

  @tag env!(["JIRA_WEBHOOK_SECRET", "JIRA_CAPTURE_DIR"])
  test "the newest captured delivery replays before and after sanitizing", %{env: env} do
    secret = env["JIRA_WEBHOOK_SECRET"]

    capture =
      env["JIRA_CAPTURE_DIR"]
      |> Path.join("jira-webhook-*.json")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
      |> Enum.max_by(& &1["captured_at"], fn ->
        flunk("no jira-webhook-*.json capture in JIRA_CAPTURE_DIR")
      end)

    event = capture["body"] |> Jason.decode!() |> Map.fetch!("webhookEvent")

    assert {:ok, %{event: ^event}} = LiveSmoke.replay(capture, webhook: Webhook, secret: secret)

    assert {:ok, %{event: ^event}} =
             capture
             |> LiveSmoke.sanitize_capture(secret: secret)
             |> LiveSmoke.replay(webhook: Webhook)
  end
end
