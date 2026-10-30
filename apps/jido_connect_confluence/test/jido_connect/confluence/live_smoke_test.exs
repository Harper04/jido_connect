defmodule Jido.Connect.Confluence.LiveSmokeTest do
  @moduledoc """
  Live smoke checks against the Atlassian Cloud test site.

      mix test --only live_smoke

  See `docs/live_smoke_tests.md` for the variables and the recording mode.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect.Confluence.{Client, TestRuntime}

  @tag env!(["CONFLUENCE_SITE", "CONFLUENCE_EMAIL", "CONFLUENCE_API_TOKEN", "CONFLUENCE_PAGE_ID"])
  test "reads the plain test page", %{env: env} do
    LiveSmoke.record({:jido_connect_confluence, :confluence_req_options}, :confluence, "page")

    assert {:ok, request} =
             [
               site_url: env["CONFLUENCE_SITE"],
               email: env["CONFLUENCE_EMAIL"],
               api_token: env["CONFLUENCE_API_TOKEN"]
             ]
             |> TestRuntime.build()
             |> Client.request_context()

    assert {:ok, page} = Client.get_page(%{id: env["CONFLUENCE_PAGE_ID"]}, request)
    assert is_map(page)
  end
end
