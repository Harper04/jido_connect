defmodule Jido.Connect.Google.Meet.TestSupport.LiveMeet do
  @moduledoc false

  # The Meet live tests read meeting data prepared on 2026-10-30. Google
  # deletes conference records and transcript entries 30 days after the
  # conference ended, so from 2026-11-29 on a live run would fail on missing
  # data. `prepared!/1` skips such a test instead. It tells expiry from
  # Google's answer, not from a date: when the run includes the live tests,
  # it asks Google once per prepared variable while the test file compiles,
  # and a 404 with status `NOT_FOUND` skips the test with the variable, the
  # preparation date and the status and reason Google sent. Any other answer
  # leaves the test to run, so it fails on a wrong ID or an expired token.

  alias Jido.Connect.Google.Meet.Client.Transport
  alias Jido.Connect.TestSupport.LiveSmoke

  @prepared_on "2026-10-30"

  @doc """
  Returns the tags of `LiveSmoke.env!/1` for `names`, plus a skip when Google
  no longer serves the prepared Meet data that one of them names.

  Only `GOOGLE_MEET_CONFERENCE_RECORD` and `GOOGLE_MEET_TRANSCRIPT` are
  checked. Google is asked only when every variable is set and the run
  includes the live tests, through `--only live_smoke` or a location in this
  file, so a plain `mix test` never calls it.
  """
  defmacro prepared!(names) do
    quote do
      Jido.Connect.Google.Meet.TestSupport.LiveMeet.prepared_tags(unquote(names), __ENV__)
    end
  end

  @doc false
  def prepared_tags(names, env) do
    tags = LiveSmoke.env_tags(names, env)

    with nil <- tags[:skip],
         true <- live_run?(env),
         token when token not in [nil, ""] <- System.get_env("GOOGLE_ACCESS_TOKEN"),
         reason when is_binary(reason) <- Enum.find_value(names, &expired(&1, token)) do
      IO.puts("live_smoke skip #{Path.relative_to_cwd(env.file)}:#{env.line}: #{reason}")
      Keyword.put(tags, :skip, reason)
    else
      _runnable -> tags
    end
  end

  defp expired(variable, token) do
    case probe(variable, System.get_env(variable), token) do
      {:ok, %{status: 404, body: %{"error" => %{"status" => "NOT_FOUND"} = error}}} ->
        "#{variable} names Meet data prepared on #{@prepared_on} that Google no longer " <>
          "serves: 404 NOT_FOUND#{reasons(error)}"

      _served_or_other ->
        nil
    end
  end

  defp probe("GOOGLE_MEET_CONFERENCE_RECORD", record, token),
    do: get(token, "/v2/#{record}", fields: "name")

  defp probe("GOOGLE_MEET_TRANSCRIPT", transcript, token),
    do: get(token, "/v2/#{transcript}/entries", pageSize: 1)

  defp probe(_variable, _value, _token), do: nil

  defp get(token, path, params) do
    token
    |> Transport.request()
    |> Req.get(url: path, params: params)
  end

  # The ErrorInfo reasons of a Google error, such as TRANSCRIPT_NOT_FOUND.
  defp reasons(%{"details" => details}) when is_list(details) do
    Enum.map_join(details, fn
      %{"reason" => reason} when is_binary(reason) -> " " <> reason
      _detail -> ""
    end)
  end

  defp reasons(_error), do: ""

  # Mirrors when LiveSmoke prints its skip reasons, plus a location in the
  # test file, which runs its live tests without the :live_smoke include.
  defp live_run?(env) do
    include = ExUnit.configuration()[:include] || []

    Enum.any?(include, fn
      :live_smoke -> true
      {:live_smoke, _value} -> true
      {:location, {file, _lines}} -> Path.expand(file) == env.file
      _other -> false
    end)
  end
end
