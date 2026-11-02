defmodule Jido.Connect.Tempo.LiveSmokeTest do
  @moduledoc """
  Live smoke checks against the Tempo test account of the Atlassian test site.

      MIX_ENV=test mix do --app jido_connect_tempo test --only live_smoke

  See `docs/live_smoke_tests.md` for the variables and the recording mode.
  The Atlassian account ID of the test user comes from Jira
  `GET /rest/api/3/myself`; that helper call is not recorded. Neither is
  the direct Tempo read that the own worklog checks compare against.

  The own worklog checks rely on the test user's prepared worklogs on
  `TEMPO_JIRA_ISSUE_ID` from August to October 2026: one on the first and
  one on the last day of each period (August 1 and 31, September 1 and 30,
  October 1 and 30); five on October 1, among them two that differ only in
  their IDs and one with zero billable seconds; and worklog 79166 on
  October 31, booked at 00:30 Europe/Berlin, so its UTC date is October 30,
  with a description of 778 bytes. The test user has no worklog in July
  2026.

  ExUnit prints the arguments of a failing call, so checks that involve a real
  token compute a boolean first and fail with a fixed message.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect.{Connection, Context, CredentialLease, Error}
  alias Jido.Connect.Tempo
  alias Jido.Connect.Tempo.Client.{Pagination, Request, Transport}
  alias Jido.Connect.Tempo.{Client, OAuth, ScopeResolver}

  @recorder {:jido_connect_tempo, :tempo_req_options}
  @oauth_recorder {:jido_connect_tempo, :tempo_oauth_req_options}
  @oauth ["TEMPO_OAUTH_CLIENT_ID", "TEMPO_OAUTH_CLIENT_SECRET", "TEMPO_OAUTH_REDIRECT_URI"]
  @october [params: [from: "2026-10-01", to: "2026-10-31"]]
  @jira ["JIRA_SITE", "JIRA_EMAIL", "JIRA_API_TOKEN"]
  @boundary_days [
    "2026-08-01",
    "2026-08-31",
    "2026-09-01",
    "2026-09-30",
    "2026-10-01",
    "2026-10-30",
    "2026-10-31"
  ]
  # This file lies in apps/jido_connect_tempo/test/jido_connect/tempo.
  @repository Path.expand("../../../../..", __DIR__)

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

  @tag env!(["TEMPO_API_TOKEN", "TEMPO_API_ORIGIN" | @jira])
  test "lists the own worklogs of the three seeded periods through the action", %{env: env} do
    token = env["TEMPO_API_TOKEN"]
    context = context!(env, :api_token)
    range = %{from: "2026-08-01", to: "2026-10-31"}
    LiveSmoke.record(@recorder, :tempo, "worklogs_own")

    result = ok!(invoke(context, :api_token, token, range), "the own worklog read")
    worklogs = result.worklogs

    assert %{from: "2026-08-01", to: "2026-10-31", complete: true} = result

    own? = result.account_id == context.connection.subject.account_id
    assert own?, "account_id is not the connection's subject.account_id"

    assert length(worklogs) > 50, "expected more than one page of 50, got #{length(worklogs)}"
    assert Enum.map(worklogs, &key/1) == Enum.map(raw_worklogs!(env, token, range), &raw_key/1)

    days = worklogs |> Enum.map(& &1.start_date) |> MapSet.new()
    assert Enum.filter(@boundary_days, &(&1 not in days)) == []

    assert Enum.any?(worklogs, &(utc_date(&1) != &1.start_date)),
           "no worklog whose booking day differs from its UTC date"

    assert Enum.any?(worklogs, &(byte_size(&1.description || "") > 512)),
           "no description longer than 512 bytes"

    assert Enum.any?(worklogs, &(&1[:billable_seconds] == 0)), "no zero billable seconds"
    assert Enum.any?(worklogs, &(rem(&1.time_spent_seconds, 3600) != 0))
    assert twins?(worklogs), "no two worklogs that differ only in their Tempo IDs"
  end

  @tag env!(["TEMPO_OAUTH_ACCESS_TOKEN", "TEMPO_API_ORIGIN" | @jira])
  test "reads October 1 in pages of two with the OAuth access token", %{env: env} do
    token = env["TEMPO_OAUTH_ACCESS_TOKEN"]
    request = request!(env, :oauth2_user, token)
    range = %{from: "2026-10-01", to: "2026-10-01"}
    LiveSmoke.record(@recorder, :tempo, "worklogs_own_small_page")

    worklogs =
      ok!(
        Client.list_own_worklogs(request, from: range.from, to: range.to, limit: 2),
        "the small page read"
      )

    assert length(worklogs) == 5

    assert Enum.map(worklogs, &key(Tempo.Worklog.to_map(&1))) ==
             Enum.map(raw_worklogs!(env, token, range), &raw_key/1)

    assert twins?(Enum.map(worklogs, &Tempo.Worklog.to_map/1)),
           "no two worklogs that differ only in their Tempo IDs"
  end

  # Tempo filters by the booking day in the worker's time zone, not by the
  # UTC date of the start. The empty range is read second in the same
  # recording: its response names the account only in links, so the
  # sanitizer must have learned the account ID from the first one.
  @tag env!(["TEMPO_OAUTH_ACCESS_TOKEN", "TEMPO_API_ORIGIN" | @jira])
  test "a one-day range holds the worklog booked after midnight, an empty range none",
       %{env: env} do
    token = env["TEMPO_OAUTH_ACCESS_TOKEN"]
    context = context!(env, :oauth2_user)
    LiveSmoke.record(@recorder, :tempo, "worklogs_own_day")

    day =
      ok!(
        invoke(context, :oauth2_user, token, %{from: "2026-10-31", to: "2026-10-31"}),
        "the one-day read"
      )

    assert %{complete: true, worklogs: [%{tempo_worklog_id: 79_166} = worklog]} = day
    assert %{start_date: "2026-10-31", start_time: "00:30:00"} = worklog
    assert utc_date(worklog) == "2026-10-30"
    assert worklog.time_spent_seconds == 1801
    assert byte_size(worklog.description) == 778

    empty =
      ok!(
        invoke(context, :oauth2_user, token, %{from: "2026-07-01", to: "2026-07-31"}),
        "the empty range read"
      )

    assert %{worklogs: [], complete: true, from: "2026-07-01", to: "2026-07-31"} = empty
  end

  # The token endpoint's rejections are recorded with an invented code and an
  # invented refresh token. A successful exchange needs the code of one
  # browser authorization and every refresh replaces both tokens, so that
  # test runs only with TEMPO_OAUTH_CODE and never uses the stored refresh
  # token.
  @tag env!(@oauth)
  test "the token endpoint rejects an invented authorization code", %{env: env} do
    LiveSmoke.record(@oauth_recorder, :tempo, "oauth_invalid_code")

    assert {:error,
            %Error.ProviderError{provider: :tempo, reason: :forbidden, status: 403} = error} =
             OAuth.exchange_code("jido-connect-invented-code", oauth_opts(env))

    refute_leak(error, env["TEMPO_OAUTH_CLIENT_SECRET"])
  end

  @tag env!(@oauth)
  test "the token endpoint rejects an invented refresh token", %{env: env} do
    LiveSmoke.record(@oauth_recorder, :tempo, "oauth_invalid_refresh_token")

    assert {:error,
            %Error.ProviderError{provider: :tempo, reason: :forbidden, status: 403} = error} =
             OAuth.refresh("jido-connect-invented-refresh-token", oauth_opts(env))

    refute_leak(error, env["TEMPO_OAUTH_CLIENT_SECRET"])
  end

  # Consumes the code and rotates the new pair once. Each pair is written to
  # TEMPO_OAUTH_TOKEN_FILE before anything else can fail: the code is spent
  # after the exchange, and the exchanged pair is invalid after the refresh.
  @tag env!(["TEMPO_OAUTH_CODE", "TEMPO_OAUTH_TOKEN_FILE", "TEMPO_API_ORIGIN"] ++ @oauth ++ @jira)
  test "exchanges a code and refreshes the new pair once", %{env: env} do
    code = env["TEMPO_OAUTH_CODE"]
    file = env["TEMPO_OAUTH_TOKEN_FILE"]
    prepare_token_file!(file)

    LiveSmoke.record(@oauth_recorder, :tempo, "oauth_exchange")
    issued_at = DateTime.utc_now()
    exchanged = token!(OAuth.exchange_code(code, oauth_opts(env)), "code exchange")
    write_token_file!(file, exchanged, issued_at)
    refute_recorded_secrets!("oauth_exchange", [code | token_values(exchanged)])

    LiveSmoke.record(@oauth_recorder, :tempo, "oauth_refresh")
    issued_at = DateTime.utc_now()
    refreshed = token!(OAuth.refresh(refresh_token(exchanged), oauth_opts(env)), "refresh")
    write_token_file!(file, refreshed, issued_at)

    refute_recorded_secrets!(
      "oauth_refresh",
      [code | token_values(exchanged) ++ token_values(refreshed)]
    )

    assert usable_token?(exchanged), "the exchanged token lacks expiry, scope or worklog read"
    assert usable_token?(refreshed), "the refreshed token lacks expiry, scope or worklog read"
    assert rotated?(exchanged, refreshed), "the refresh returned a token of the exchanged pair"

    read =
      env
      |> request!(:oauth2_user, access_token(refreshed))
      |> Transport.get("/4/periods", @october)

    assert match?({:ok, %{"periods" => [_ | _]}}, read),
           "the refreshed access token did not read /4/periods"

    stale =
      env
      |> request!(:oauth2_user, access_token(exchanged))
      |> Transport.get("/4/periods", @october)

    assert match?({:error, %Error.ProviderError{reason: :unauthorized, status: 401}}, stale),
           "the exchanged access token did not get a 401 after the refresh"
  end

  # The helpers below take token maps. Each has a clause for any argument, so
  # no FunctionClauseError prints a token.

  defp token!({:ok, %{access_token: _, refresh_token: _} = token}, _step), do: token

  defp token!({:error, %Error.ProviderError{} = error}, step),
    do: flunk("the #{step} failed: #{inspect(error.reason)}, status #{inspect(error.status)}")

  defp token!(_result, step), do: flunk("the #{step} returned an unexpected result")

  defp access_token(%{access_token: token}), do: token
  defp access_token(_token), do: flunk("no access token")

  defp refresh_token(%{refresh_token: token}), do: token
  defp refresh_token(_token), do: flunk("no refresh token")

  defp token_values(%{access_token: access, refresh_token: refresh}), do: [access, refresh]
  defp token_values(_token), do: flunk("no token pair")

  defp usable_token?(%{expires_in: expires_in, scope: [_ | _] = scope})
       when is_integer(expires_in) and expires_in > 0,
       do: "tempo.worklogs.read" in ScopeResolver.granted_labels(scope)

  defp usable_token?(_token), do: false

  defp rotated?(%{access_token: a1, refresh_token: r1}, %{access_token: a2, refresh_token: r2}),
    do: a1 != a2 and r1 != r2

  defp rotated?(_exchanged, _refreshed), do: false

  # The file must be an absolute path outside the repository, so no commit can
  # pick up the pair; Mix runs the test in the app directory, where a relative
  # path would land. It must be new or empty, so a run cannot overwrite an env
  # file. It is created with mode 0600 at once, which also shows that its
  # directory is writable before the code is spent.
  defp prepare_token_file!(file) do
    unless outside_repository?(file),
      do: flunk("TEMPO_OAUTH_TOKEN_FILE must be an absolute path outside the repository")

    case File.read(file) do
      {:ok, ""} -> :ok
      {:error, :enoent} -> :ok
      _other -> flunk("TEMPO_OAUTH_TOKEN_FILE must name a missing or empty file")
    end

    File.write!(file, "")
    File.chmod!(file, 0o600)
  end

  defp outside_repository?(file) do
    Path.type(file) == :absolute and
      not String.starts_with?(Path.expand(file) <> "/", @repository <> "/")
  end

  # Writes a temporary file with mode 0600 before any secret goes in, then
  # renames it over the token file, so the previous pair stays readable until
  # the new one is complete.
  defp write_token_file!(file, %{access_token: access, refresh_token: refresh} = token, issued_at) do
    temporary = file <> ".tmp"
    File.write!(temporary, "")
    File.chmod!(temporary, 0o600)

    File.write!(temporary, [
      "TEMPO_OAUTH_ACCESS_TOKEN=#{access}\n",
      "TEMPO_OAUTH_REFRESH_TOKEN=#{refresh}\n",
      expires_at_line(token, issued_at)
    ])

    File.rename!(temporary, file)
  end

  defp write_token_file!(_file, _token, _issued_at), do: flunk("no token pair to write")

  defp expires_at_line(%{expires_in: seconds}, issued_at) when is_integer(seconds) do
    expires_at =
      issued_at |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

    "TEMPO_OAUTH_ACCESS_TOKEN_EXPIRES_AT=#{DateTime.to_iso8601(expires_at)}\n"
  end

  defp expires_at_line(_token, _issued_at), do: []

  # The recorder redacts token fields by key and checks configured
  # credentials; freshly issued tokens are not configured, so this checks the
  # written fixture for them and for the code.
  defp refute_recorded_secrets!(name, secrets) do
    if LiveSmoke.recording?() do
      path = Path.join([File.cwd!(), "test", "fixtures", "tempo", "recorded", name <> ".json"])
      text = File.read!(path)

      if Enum.any?(secrets, &String.contains?(text, &1)) do
        File.rm!(path)
        flunk("#{name}.json contained a token or the code and was deleted")
      end
    end
  end

  defp oauth_opts(env) do
    [
      client_id: env["TEMPO_OAUTH_CLIENT_ID"],
      client_secret: env["TEMPO_OAUTH_CLIENT_SECRET"],
      redirect_uri: env["TEMPO_OAUTH_REDIRECT_URI"]
    ]
  end

  defp refute_leak(error, secret) do
    leaked? =
      String.contains?(inspect(error), secret) or
        String.contains?(inspect(Error.to_map(error)), secret)

    refute leaked?, "the normalized error contains the token"
  end

  defp invoke(%Context{connection: connection} = context, profile, token, input) do
    field = if profile == :api_token, do: :api_token, else: :access_token

    lease =
      CredentialLease.from_connection!(connection, %{field => token},
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
      )

    Jido.Connect.invoke(Tempo, "tempo.worklogs.list_own", input,
      context: context,
      credential_lease: lease
    )
  end

  defp ok!({:ok, value}, _step), do: value

  defp ok!({:error, error}, step),
    do:
      flunk(
        "#{step} failed: #{inspect(Map.get(error, :reason))}, status #{inspect(Map.get(error, :status))}"
      )

  # The compared fields, without the author, whose account ID the output
  # of a failing comparison would show.
  defp key(worklog) do
    {worklog.tempo_worklog_id, worklog.start_date, worklog.time_spent_seconds,
     worklog[:billable_seconds], worklog.issue_id}
  end

  defp raw_key(record) do
    {record["tempoWorklogId"], record["startDate"], record["timeSpentSeconds"],
     record["billableSeconds"], record["issue"]["id"]}
  end

  defp utc_date(%{start_date_time_utc: utc}), do: String.slice(utc, 0, 10)

  defp twins?(worklogs) do
    worklogs
    |> Enum.group_by(&Map.drop(&1, [:tempo_worklog_id, :self, :created_at, :updated_at]))
    |> Enum.any?(fn {_shape, group} -> length(group) > 1 end)
  end

  # Reads the Tempo records directly, outside the package and the recorder,
  # in one page.
  defp raw_worklogs!(env, token, %{from: from, to: to}) do
    path = "/4/worklogs/user/" <> URI.encode(account_id!(env), &URI.char_unreserved?/1)

    case Req.get(env["TEMPO_API_ORIGIN"] <> path,
           auth: {:bearer, token},
           params: [from: from, to: to, offset: 0, limit: 1000],
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"results" => results, "metadata" => metadata}}}
      when not is_map_key(metadata, "next") ->
        results

      _other ->
        flunk("the direct Tempo read did not return one complete page")
    end
  end

  defp context!(env, profile) do
    Context.new!(%{
      tenant_id: "live",
      actor: %{id: "live", type: :app_user},
      connection: connection!(env, profile, env["TEMPO_API_ORIGIN"], ["tempo.worklogs.read"])
    })
  end

  defp connection!(env, profile, origin, scopes) do
    Connection.new!(%{
      id: "tempo_live_#{profile}",
      provider: :tempo,
      profile: profile,
      tenant_id: "live",
      owner_type: :app_user,
      owner_id: "live",
      subject: %{account_id: account_id!(env)},
      status: :connected,
      scopes: scopes,
      metadata: %{api_origin: origin}
    })
  end

  defp request!(env, profile, token, origin \\ nil) do
    field = if profile == :api_token, do: :api_token, else: :access_token
    connection = connection!(env, profile, origin || env["TEMPO_API_ORIGIN"], [])

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
