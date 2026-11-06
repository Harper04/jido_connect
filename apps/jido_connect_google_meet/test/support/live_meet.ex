defmodule Jido.Connect.Google.Meet.TestSupport.LiveMeet do
  @moduledoc """
  Skips the Meet live tests whose prepared meeting data Google has deleted.

  Google deletes a conference record, and the transcript entries under it,
  30 days after the conference ends. The prepared data of the test account
  dates from `@prepared_on`; once Google has deleted it, the live tests that
  read it cannot pass. A live test that reads prepared data adds a
  `prepared!/1` tag after its `env!/1` tag and lists the prepared variables it
  reads. A recording lives under its conference record, so a test of a
  recording lists `GOOGLE_MEET_CONFERENCE_RECORD`.

      alias Jido.Connect.Google.Meet.TestSupport.LiveMeet
      require LiveMeet

      @tag env!(["GOOGLE_ACCESS_TOKEN", "GOOGLE_MEET_CONFERENCE_RECORD", "GOOGLE_MEET_TRANSCRIPT"])
      @tag LiveMeet.prepared!(["GOOGLE_MEET_CONFERENCE_RECORD", "GOOGLE_MEET_TRANSCRIPT"])
      test "pages through transcript entries", %{env: env} do
        ...
      end

  ExUnit decides skips from tags before any setup runs, so `prepared!/1`,
  like `env!/1`, runs when the test file compiles. It returns
  `[live_meet_prepared: variables]` and adds `skip:` with a reason when a
  variable names deleted data. It asks Google only in a run that can include
  the test: `--only live_smoke`, `--include live_smoke`, or `mix test` with a
  location in the test's file. A plain `mix test` asks nothing, and neither
  does a run without `GOOGLE_ACCESS_TOKEN` or with the variable unset, which
  `env!/1` already skips. It checks the variables in the given order and names
  the first one whose data is gone. Each variable and value is asked once per
  VM; the cache key holds no token. Any variable other than the two below
  raises `ArgumentError` when the file compiles.

  `probe/3` sends a variable's request with `GOOGLE_ACCESS_TOKEN`:
  `conferenceRecords.get` with `fields=name` for
  `GOOGLE_MEET_CONFERENCE_RECORD`, and one page of `transcripts.entries.list`
  with the entry names only, no text, for `GOOGLE_MEET_TRANSCRIPT`. It
  returns Google's answer as Req returns it, because the Meet client's
  `ProviderError` keeps neither Google's `error.status` nor the ErrorInfo
  reason.

  `expired?/1` reads two answers as deleted data: 404 `NOT_FOUND`, and 403
  `PERMISSION_DENIED` without an ErrorInfo reason whose message says the
  resource might not exist, Google's answer for a conference record that does
  not exist. Every other answer, among them success, 401, a 403 with
  `ACCESS_TOKEN_SCOPE_INSUFFICIENT`, 400, 5xx and transport errors, leaves the
  test to run and fail. The skip reason names the variable, `@prepared_on`,
  the status, Google's `error.status` and the ErrorInfo reason or else
  Google's message. A run that asked Google prints it as the harness prints
  `env!/1` skips:

      live_smoke skip test/jido_connect/google/meet/live_smoke_test.exs:70: GOOGLE_MEET_CONFERENCE_RECORD, prepared on 2026-10-30, has expired: Google answered 403 PERMISSION_DENIED "Permission denied on resource Conference (or it might not exist)"; see "Prepared Meet data" in docs/live_smoke_tests.md

  With fresh meeting data, change `@prepared_on`; "Prepared Meet data" in
  `docs/live_smoke_tests.md` lists what else changes with it.
  """

  alias Jido.Connect.Google.Meet.Client.Transport

  # The day the prepared Meet data was created. Change it with fresh data.
  @prepared_on ~D[2026-10-30]

  @variables ~w(GOOGLE_MEET_CONFERENCE_RECORD GOOGLE_MEET_TRANSCRIPT)
  @error_info "type.googleapis.com/google.rpc.ErrorInfo"
  @docs ~s(see "Prepared Meet data" in docs/live_smoke_tests.md)

  @doc """
  Returns the tags of a live test that reads the prepared Meet `variables`,
  with `skip:` when Google has deleted the data of one of them.
  """
  defmacro prepared!(variables) do
    quote do
      Jido.Connect.Google.Meet.TestSupport.LiveMeet.prepared_tags(unquote(variables), __ENV__)
    end
  end

  @doc false
  def prepared_tags(variables, %Macro.Env{} = env) when is_list(variables) do
    Enum.each(variables, &known_variable!/1)
    tags = [live_meet_prepared: variables]

    case expired_variable(variables, env) do
      nil -> tags
      {variable, answer} -> Keyword.put(tags, :skip, skip_reason(variable, answer, env))
    end
  end

  @doc "Tells whether a result of `probe/3` is Google's answer for deleted data."
  @spec expired?({:ok, Req.Response.t()} | {:error, Exception.t()}) :: boolean()
  def expired?(result), do: match?({:expired, _answer}, classify(result))

  @doc "Sends the request that `prepared!/1` sends for `variable` with value `name`."
  @spec probe(String.t(), String.t(), String.t()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def probe(variable, name, access_token)

  def probe("GOOGLE_MEET_CONFERENCE_RECORD", name, access_token) do
    get(access_token, "/v2/" <> encode(name), fields: "name")
  end

  def probe("GOOGLE_MEET_TRANSCRIPT", name, access_token) do
    get(access_token, "/v2/" <> encode(name) <> "/entries",
      pageSize: 1,
      fields: "transcriptEntries(name)"
    )
  end

  # Clears the cache, for the offline tests of this module.
  @doc false
  def forget do
    for {{__MODULE__, _variable, _value} = key, _answer} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    :ok
  end

  defp get(access_token, path, params) do
    access_token
    |> Transport.request()
    |> Req.get(url: path, params: params)
  end

  defp encode(name) do
    name
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))
  end

  defp expired_variable(variables, env) do
    access_token = System.get_env("GOOGLE_ACCESS_TOKEN")

    if live_run?(env) and not blank?(access_token) do
      Enum.find_value(variables, fn variable ->
        value = System.get_env(variable)

        with false <- blank?(value),
             {:expired, answer} <- cached(variable, value, access_token) do
          {variable, answer}
        else
          _not_expired -> nil
        end
      end)
    end
  end

  # Test files compile in parallel, so the lock keeps a second file from
  # asking while the first waits for Google. The key holds no token.
  defp cached(variable, value, access_token) do
    key = {__MODULE__, variable, value}

    :global.trans({key, self()}, fn ->
      case :persistent_term.get(key, nil) do
        nil ->
          outcome = variable |> probe(value, access_token) |> classify()
          :persistent_term.put(key, outcome)
          outcome

        outcome ->
          outcome
      end
    end)
  end

  # `--only live_smoke` and `--include live_smoke` include the tag;
  # `mix test <file>:<line>` includes locations, with or without lines.
  defp live_run?(env) do
    include = ExUnit.configuration()[:include] || []

    Enum.any?(include, fn
      :live_smoke -> true
      {:live_smoke, _value} -> true
      {:location, {path, _lines}} -> String.ends_with?(env.file, path)
      {:location, path} when is_binary(path) -> String.ends_with?(env.file, path)
      _filter -> false
    end)
  end

  defp classify({:ok, %{status: 404, body: %{"error" => %{"status" => "NOT_FOUND"} = error}}}),
    do: {:expired, answer(404, error)}

  defp classify(
         {:ok, %{status: 403, body: %{"error" => %{"status" => "PERMISSION_DENIED"} = error}}}
       ) do
    if is_nil(error_reason(error)) and might_not_exist?(error["message"]),
      do: {:expired, answer(403, error)},
      else: :not_expired
  end

  defp classify(_result), do: :not_expired

  # Status, Google's error status, and the ErrorInfo reason or else the message.
  defp answer(status, error) do
    "#{status} #{error["status"]} " <> (error_reason(error) || inspect(error["message"]))
  end

  defp error_reason(%{"details" => details}) when is_list(details) do
    Enum.find_value(details, fn
      %{"@type" => @error_info, "reason" => reason} when is_binary(reason) -> reason
      _detail -> nil
    end)
  end

  defp error_reason(_error), do: nil

  defp might_not_exist?(message) when is_binary(message), do: message =~ "might not exist"
  defp might_not_exist?(_message), do: false

  defp skip_reason(variable, answer, env) do
    reason =
      "#{variable}, prepared on #{Date.to_iso8601(@prepared_on)}, has expired: " <>
        "Google answered #{answer}; #{@docs}"

    IO.puts("live_smoke skip #{Path.relative_to_cwd(env.file)}:#{env.line}: #{reason}")
    reason
  end

  defp known_variable!(variable) when variable in @variables, do: :ok

  defp known_variable!(variable) do
    raise ArgumentError,
          "#{inspect(variable)} is not prepared Meet data that prepared!/1 can check; " <>
            "use #{Enum.join(@variables, " or ")}"
  end

  defp blank?(value), do: value in [nil, ""]
end
