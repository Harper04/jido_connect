Code.require_file("live_smoke/sanitize.ex", __DIR__)
Code.require_file("live_smoke/recorder.ex", __DIR__)

defmodule Jido.Connect.TestSupport.LiveSmoke do
  @moduledoc """
  Live smoke convention for provider test accounts.

  Live tests carry the `:live_smoke` tag. Test helpers exclude it, so a plain
  `mix test` never calls a provider; `mix test --only live_smoke` runs them.
  Credentials and test data IDs come from environment variables, listed with
  the rest of the convention in `docs/live_smoke_tests.md`.

      defmodule Jido.Connect.Slack.LiveSmokeTest do
        use ExUnit.Case, async: false
        use Jido.Connect.TestSupport.LiveSmoke

        @tag env!(["SLACK_BOT_TOKEN"])
        test "auth.test accepts the bot token", %{env: env} do
          LiveSmoke.record({:jido_connect_slack, :slack_req_options}, :slack, "auth_test")
          assert {:ok, _identity} = Jido.Connect.Slack.Client.auth_test(env["SLACK_BOT_TOKEN"])
        end

        @tag env!(["SLACK_BOT_TOKEN", "SLACK_PUBLIC_CHANNEL_ID"])
        @tag write!(:slack)
        test "posts and deletes a message", %{env: env} do
          ...
        end
      end

  `env!/1` and `write!/1` are evaluated when the test file compiles, which is
  when `mix test` runs, so a missing variable or a closed write gate turns into
  an ExUnit skip that names the variable.
  """

  alias Jido.Connect.TestSupport.LiveSmoke.{Recorder, Sanitize}

  # One entry per provider. A provider's first live test adds its variables
  # here and to docs/live_smoke_tests.md; a test checks that both agree.
  @variables %{
    slack: %{
      credentials: ~w(SLACK_BOT_TOKEN),
      settings: ~w(SLACK_PUBLIC_CHANNEL_ID)
    }
  }

  defmacro __using__(_opts) do
    quote do
      alias Jido.Connect.TestSupport.LiveSmoke
      import Jido.Connect.TestSupport.LiveSmoke, only: [env!: 1, write!: 1]

      @moduletag :live_smoke
      setup {Jido.Connect.TestSupport.LiveSmoke, :setup_live_env}
    end
  end

  @doc "Returns the variables of the convention by provider."
  @spec variables() :: %{atom() => %{credentials: [String.t()], settings: [String.t()]}}
  def variables, do: @variables

  @doc """
  Returns tags for a test that reads `names` from the environment.

  An unset or empty variable adds a `:skip` tag naming it. ExUnit does not
  print skip reasons, so a run that includes `:live_smoke` also prints the
  reason with the test's file and line. The setup from `use LiveSmoke` puts
  the values into the test context under `:env`.
  """
  defmacro env!(names) do
    quote do
      Jido.Connect.TestSupport.LiveSmoke.env_tags(unquote(names), __ENV__)
    end
  end

  @doc """
  Returns tags for a test that writes to the provider account.

  The test is skipped unless `<PROVIDER>_LIVE_DESTRUCTIVE=true`.
  """
  defmacro write!(provider) do
    quote do
      Jido.Connect.TestSupport.LiveSmoke.write_tags(unquote(provider), __ENV__)
    end
  end

  @doc false
  @spec env_tags([String.t()], Macro.Env.t()) :: keyword()
  def env_tags(names, env) when is_list(names) do
    Enum.each(names, &known_variable!/1)

    case Enum.filter(names, &blank?(System.get_env(&1))) do
      [] ->
        [live_env: names]

      missing ->
        [
          live_env: names,
          skip: skip_reason("set #{Enum.join(missing, ", ")} to run this live test", env)
        ]
    end
  end

  @doc false
  @spec write_tags(atom(), Macro.Env.t()) :: keyword()
  def write_tags(provider, env) do
    variable = destructive_variable!(provider)

    if System.get_env(variable) == "true" do
      [live_write: provider]
    else
      [
        live_write: provider,
        skip: skip_reason("set #{variable}=true to run this live write", env)
      ]
    end
  end

  @doc false
  def setup_live_env(context) do
    check_write_gate!(context[:live_write])

    case context[:live_env] do
      nil -> :ok
      names -> %{env: Map.new(names, &{&1, fetch_env!(&1)})}
    end
  end

  @doc "Returns whether `JIDO_CONNECT_RECORD=1` asks to record provider responses."
  @spec recording?() :: boolean()
  def recording?, do: System.get_env("JIDO_CONNECT_RECORD") == "1"

  @doc """
  Records the responses of the current test when `JIDO_CONNECT_RECORD=1`.

  `target` names a package's Req options, such as
  `{:jido_connect_slack, :slack_req_options}`. The recorder joins them as the
  Req adapter until the test exits and writes each response, sanitized, to
  `test/fixtures/<provider>/recorded/<name>.json`; later responses of the same
  test go to `<name>.2.json`, `<name>.3.json` and so on.

  Options are `:root` (default: the current directory), `:transform` and the
  sanitizer options of `sanitize/2`. Without `JIDO_CONNECT_RECORD=1` this
  does nothing.

  `:transform` is a function of the decoded request path and the decoded
  response body. It returns the body to record, or `:skip` to write no
  fixture for that response; a skipped response takes no number. It runs
  before the sanitizer, whose leak guard checks its result, and it changes
  only the fixture, never the response the caller gets. Use it to leave out
  or neutralize data that a shared test account returns besides the test
  data, such as other users' entries, and say in the test what it changes.
  A fixture whose body the transform changed carries `"transformed": true`;
  its headers, such as `content-length`, still describe the provider's
  response.
  """
  @spec record({atom(), atom()}, atom() | String.t(), String.t(), keyword()) :: :ok
  def record({app, key}, provider, name, opts \\ []) when is_atom(app) and is_atom(key) do
    if recording?() do
      {transform, opts} = Keyword.pop(opts, :transform)
      check_transform!(transform)
      patch_req_options!(app, key)

      session = %{
        dir: fixture_dir(provider, opts),
        name: name,
        count: 0,
        transform: transform,
        sanitizer: sanitizer(opts)
      }

      case Process.whereis(Recorder) do
        nil -> ExUnit.Callbacks.start_supervised!({Recorder, session})
        _pid -> Recorder.switch(session)
      end
    end

    :ok
  end

  @doc """
  Returns the body of a recorded fixture, unchanged, for `Req.Test.json/2`.

      Req.Test.stub(MyStub, &Req.Test.json(&1, LiveSmoke.fixture!(:slack, "auth_test")))
  """
  @spec fixture!(atom() | String.t(), String.t(), keyword()) :: term()
  def fixture!(provider, name, opts \\ []) do
    provider
    |> fixture_dir(opts)
    |> Path.join("#{name}.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("body")
  end

  @doc """
  Sanitizes a decoded provider value.

  Redacts the sensitive keys of `Jido.Connect.Sanitizer` except `:keep_keys`
  (default `["fields"]`, the record payload of providers such as Jira and
  Airtable), replaces email addresses and display names with stable
  placeholders, and replaces the values under `:fields` with `<field>-<n>`.
  `:name_keys` adds keys that hold display names. Raises `LeakError` when the
  value of a credential variable or a configured email address remains.
  """
  @spec sanitize(term(), keyword()) :: term()
  def sanitize(value, opts \\ []) do
    {sanitized, state} = Sanitize.value(value, sanitizer(opts))
    Sanitize.check_leaks!(sanitized, state)
    sanitized
  end

  @doc """
  Sanitizes a recorded fixture again, as the recorder sanitized it.

  `fixture` is the decoded content of a file that `record/4` wrote. The
  body, the headers and the request path pass through the sanitizer in the
  recorder's order; the rest stays. Options are those of `sanitize/2`. A
  committed fixture that comes out changed, or raises `LeakError`, holds
  something the current sanitizer would not have written.
  """
  @spec sanitize_fixture(map(), keyword()) :: map()
  def sanitize_fixture(fixture, opts \\ []) do
    {sanitized, state} = Sanitize.fixture(fixture, sanitizer(opts))
    Sanitize.check_leaks!(sanitized, state)
    sanitized
  end

  @doc """
  Raises `LeakError` when `value`, as it is, holds the value of a credential
  variable or a configured email address.

  Nothing is sanitized first, so values under keys that the sanitizer redacts
  are checked too. Use it for fixtures written by hand.
  """
  @spec check_leaks!(term(), keyword()) :: :ok
  def check_leaks!(value, opts \\ []), do: Sanitize.check_leaks!(value, sanitizer(opts))

  defp skip_reason(reason, env) do
    include = ExUnit.configuration()[:include] || []

    if Enum.any?(include, &(&1 == :live_smoke or match?({:live_smoke, _value}, &1))) do
      IO.puts("live_smoke skip #{Path.relative_to_cwd(env.file)}:#{env.line}: #{reason}")
    end

    reason
  end

  defp known_variable!(name) do
    known? =
      Enum.any?(@variables, fn {_provider, groups} ->
        name in groups.credentials or name in groups.settings
      end)

    unless known? do
      raise ArgumentError,
            "#{name} is not a live smoke variable; add it to LiveSmoke and docs/live_smoke_tests.md"
    end
  end

  defp destructive_variable!(provider) when is_map_key(@variables, provider),
    do: "#{provider |> Atom.to_string() |> String.upcase()}_LIVE_DESTRUCTIVE"

  defp destructive_variable!(provider) do
    raise ArgumentError,
          "#{inspect(provider)} is not a live smoke provider; use one of " <>
            inspect(Map.keys(@variables))
  end

  defp check_write_gate!(nil), do: :ok
  defp check_write_gate!(false), do: :ok

  defp check_write_gate!(provider) when is_atom(provider) and is_map_key(@variables, provider) do
    variable = destructive_variable!(provider)

    unless System.get_env(variable) == "true" do
      raise ArgumentError, "set #{variable}=true to run this live write"
    end
  end

  defp check_write_gate!(_tag) do
    raise ArgumentError, "tag live writes with write!/1 so the provider's gate applies"
  end

  defp check_transform!(nil), do: :ok
  defp check_transform!(transform) when is_function(transform, 2), do: :ok

  defp check_transform!(_transform) do
    raise ArgumentError, ":transform must be a function of the request path and the body"
  end

  defp patch_req_options!(app, key) do
    previous = Application.fetch_env(app, key)
    options = with {:ok, options} <- previous, do: options, else: (_error -> [])

    if Keyword.has_key?(options, :plug) do
      raise ArgumentError,
            "remove :plug from #{inspect(app)} #{inspect(key)} to record live responses"
    end

    unless options[:adapter] == Recorder do
      Application.put_env(app, key, Keyword.put(options, :adapter, Recorder))
      ExUnit.Callbacks.on_exit(fn -> restore_env(app, key, previous) end)
    end
  end

  defp restore_env(app, key, {:ok, options}), do: Application.put_env(app, key, options)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)

  defp sanitizer(opts) do
    opts
    |> Keyword.put(:credentials, credential_values())
    |> Keyword.put(:identifying, configured_emails())
    |> Sanitize.new()
  end

  # Listed settings and every set variable ending in _EMAIL whose value is an address.
  defp configured_emails do
    listed = for {_provider, groups} <- @variables, name <- groups.settings, do: name
    shaped = for {name, _value} <- System.get_env(), String.ends_with?(name, "_EMAIL"), do: name

    for name <- Enum.uniq(listed ++ shaped),
        value = System.get_env(name),
        not blank?(value) and Regex.match?(~r/^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$/, value),
        do: {name, value}
  end

  # Listed credentials plus every set variable whose name looks like one, so a
  # token added to an env file before it is listed here is still guarded.
  defp credential_values do
    listed = for {_provider, groups} <- @variables, name <- groups.credentials, do: name

    shaped =
      for {name, _value} <- System.get_env(),
          Regex.match?(~r/(TOKEN|SECRET|PASSWORD|API_KEY)$/, name),
          do: name

    for name <- Enum.uniq(listed ++ shaped),
        value = System.get_env(name),
        not blank?(value),
        do: {name, value}
  end

  defp fixture_dir(provider, opts) do
    Path.join([
      Keyword.get(opts, :root, File.cwd!()),
      "test",
      "fixtures",
      to_string(provider),
      "recorded"
    ])
  end

  defp fetch_env!(name) do
    case System.get_env(name) do
      value when value in [nil, ""] -> raise ArgumentError, "set #{name} to run this live test"
      value -> value
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
