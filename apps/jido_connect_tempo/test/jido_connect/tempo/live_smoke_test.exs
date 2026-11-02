defmodule Jido.Connect.Tempo.LiveSmokeTest do
  @moduledoc """
  Live smoke checks against the Tempo test account of the Atlassian test site.

      MIX_ENV=test mix do --app jido_connect_tempo test --only live_smoke

  See `docs/live_smoke_tests.md` for the variables and the recording mode.
  The Atlassian account ID of the test user comes from Jira
  `GET /rest/api/3/myself`; that helper call is not recorded.

  ExUnit prints the arguments of a failing call, so checks that involve a real
  token compute a boolean first and fail with a fixed message.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect.{Connection, Error}
  alias Jido.Connect.Tempo.Client.{Pagination, Request, Transport}

  @recorder {:jido_connect_tempo, :tempo_req_options}
  @october [params: [from: "2026-10-01", to: "2026-10-31"]]
  @jira ["JIRA_SITE", "JIRA_EMAIL", "JIRA_API_TOKEN"]

  @tag env!(["TEMPO_API_TOKEN", "TEMPO_API_ORIGIN" | @jira])
  test "reads periods with the API token", %{env: env} do
    request = request!(env, :api_token, env["TEMPO_API_TOKEN"])
    LiveSmoke.record(@recorder, :tempo, "periods")

    assert {:ok, %{"periods" => [_ | _]}} = Transport.get(request, "/4/periods", @october)
  end

  @tag env!(["TEMPO_OAUTH_ACCESS_TOKEN", "TEMPO_API_ORIGIN" | @jira])
  test "reads periods with the OAuth access token", %{env: env} do
    request = request!(env, :oauth2_user, env["TEMPO_OAUTH_ACCESS_TOKEN"])
    LiveSmoke.record(@recorder, :tempo, "periods_oauth")

    assert {:ok, %{"periods" => [_ | _]}} = Transport.get(request, "/4/periods", @october)
  end

  @tag env!(["TEMPO_API_ORIGIN" | @jira])
  test "an invalid token gets a normalized auth error without the token", %{env: env} do
    token = "jido-connect-invalid-tempo-token"
    request = request!(env, :api_token, token)
    LiveSmoke.record(@recorder, :tempo, "unauthorized")

    assert {:error,
            %Error.ProviderError{provider: :tempo, reason: :unauthorized, status: 401} = error} =
             Transport.get(request, "/4/periods", @october)

    refute_leak(error, token)
  end

  @tag env!(["TEMPO_API_TOKEN" | @jira])
  test "a token sent to another cluster gets an auth error", %{env: env} do
    token = env["TEMPO_API_TOKEN"]
    request = request!(env, :api_token, token, "https://api.eu.tempo.io")
    LiveSmoke.record(@recorder, :tempo, "wrong_cluster")

    assert {:error, %Error.ProviderError{reason: :unauthorized, status: 401} = error} =
             Transport.get(request, "/4/periods", @october)

    refute_leak(error, token)
  end

  @tag env!(["TEMPO_API_TOKEN", "TEMPO_API_ORIGIN" | @jira])
  test "an unknown worklog gets a not-found error", %{env: env} do
    request = request!(env, :api_token, env["TEMPO_API_TOKEN"])
    LiveSmoke.record(@recorder, :tempo, "not_found")

    assert {:error, %Error.ProviderError{reason: :not_found, status: 404, details: details}} =
             Transport.get(request, "/4/worklogs/999999999")

    assert details.message == "Worklog cannot be found"
  end

  @tag env!(["TEMPO_API_TOKEN", "TEMPO_API_ORIGIN" | @jira])
  test "an unknown route gets a not-found error with a non-JSON body", %{env: env} do
    request = request!(env, :api_token, env["TEMPO_API_TOKEN"])
    LiveSmoke.record(@recorder, :tempo, "not_found_html")

    assert {:error, %Error.ProviderError{reason: :not_found, status: 404}} =
             Transport.get(request, "/4/global-configurations")
  end

  @tag env!(["TEMPO_API_TOKEN", "TEMPO_API_ORIGIN" | @jira])
  test "an invalid date gets a bad-request error", %{env: env} do
    request = request!(env, :api_token, env["TEMPO_API_TOKEN"])
    LiveSmoke.record(@recorder, :tempo, "bad_request")

    assert {:error, %Error.ProviderError{reason: :bad_request, status: 400, details: details}} =
             Transport.get(request, "/4/periods", params: [from: "not-a-date", to: "2026-10-31"])

    assert details.message =~ "not-a-date"
  end

  @tag env!(["TEMPO_API_TOKEN", "TEMPO_API_ORIGIN" | @jira])
  test "a read the test user may not do gets a forbidden error", %{env: env} do
    request = request!(env, :api_token, env["TEMPO_API_TOKEN"])
    LiveSmoke.record(@recorder, :tempo, "forbidden")

    assert {:error, %Error.ProviderError{reason: :forbidden, status: 403}} =
             Transport.get(request, "/4/holiday-schemes")
  end

  @tag env!(["TEMPO_API_TOKEN", "TEMPO_API_ORIGIN" | @jira])
  test "pages through the October worklogs of the test user", %{env: env} do
    request = request!(env, :api_token, env["TEMPO_API_TOKEN"])
    path = "/4/worklogs/user/" <> URI.encode(request.account_id, &URI.char_unreserved?/1)
    LiveSmoke.record(@recorder, :tempo, "worklogs_page")

    assert {:ok, worklogs} = Pagination.collect(request, path, @october)

    count = length(worklogs)
    assert count > 50, "expected more than one page of 50 worklogs, got #{count}"
    own? = Enum.all?(worklogs, &(get_in(&1, ["author", "accountId"]) == request.account_id))
    assert own?, "every worklog belongs to the test user"
  end

  defp refute_leak(error, secret) do
    leaked? =
      String.contains?(inspect(error), secret) or
        String.contains?(inspect(Error.to_map(error)), secret)

    refute leaked?, "the normalized error contains the token"
  end

  defp request!(env, profile, token, origin \\ nil) do
    field = if profile == :api_token, do: :api_token, else: :access_token

    connection =
      Connection.new!(%{
        id: "tempo_live_#{profile}",
        provider: :tempo,
        profile: profile,
        tenant_id: "live",
        owner_type: :app_user,
        owner_id: "live",
        subject: %{account_id: account_id!(env)},
        status: :connected,
        scopes: [],
        metadata: %{api_origin: origin || env["TEMPO_API_ORIGIN"]}
      })

    case Request.new(connection, %{field => token}) do
      {:ok, request} -> request
      {:error, error} -> flunk("Tempo request rejected: #{inspect(error.reason)}")
    end
  end

  defp account_id!(env) do
    case Req.get(env["JIRA_SITE"] <> "/rest/api/3/myself",
           auth: {:basic, "#{env["JIRA_EMAIL"]}:#{env["JIRA_API_TOKEN"]}"},
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"accountId" => id}}} when is_binary(id) -> id
      _other -> flunk("Jira /rest/api/3/myself did not return an account ID")
    end
  end
end
