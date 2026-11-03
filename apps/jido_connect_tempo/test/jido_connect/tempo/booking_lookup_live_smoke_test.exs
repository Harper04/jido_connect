defmodule Jido.Connect.Tempo.BookingLookupLiveSmokeTest do
  @moduledoc """
  Live smoke checks of the booking lookup against the Atlassian test site:
  the site's work attributes and the account candidates of the test project.

      MIX_ENV=test mix do --app jido_connect_tempo test --include live_smoke \\
        test/jido_connect/tempo/booking_lookup_live_smoke_test.exs

  The account checks hold on the accounts of the test data alone:
  JCL-PROJECT (`TEMPO_ACCOUNT_ID`, the default link), JCL-SECONDARY and the
  closed JCL-CLOSED, linked to `TEMPO_JIRA_PROJECT_ID`, and the global
  JCL-GLOBAL. The site is shared with real users, and Tempo returns their
  global accounts next to these; the checks assert nothing about those
  accounts beyond that the read succeeds.

  The work attribute checks need the four test attributes `_JclPhase_`
  (STATIC_LIST with the labels analysis, build and review), `_JclBillable_`
  (CHECKBOX), `_JclHours_` (INPUT_NUMERIC) and `_JclAccount_` (ACCOUNT).
  They exist on the site only around a run: the seed script
  `tempo_attributes.py up` creates them, required unless `--optional`, and
  gives the seeded worklog of October 1, 2026 the values build, true, 1.5
  and JCL-PROJECT; `down` deletes them. Without them these checks fail. The
  attribute check compares with that configured form, required or optional
  as the window created it, and names the recording after the mode it
  observed: `work_attributes_required` or `work_attributes_optional`.

  Recordings leave out what the shared site returns besides the test data
  (see `site_data/1`). The test user's account ID comes from Jira
  `GET /rest/api/3/myself`; that call and the direct Tempo reads that the
  checks compare against are not recorded. ExUnit prints the arguments of a
  failing call, so checks that involve the account ID or the site's other
  data compute a boolean first and fail with a fixed message.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect.{Connection, Context, CredentialLease, Error}
  alias Jido.Connect.Tempo
  alias Jido.Connect.Tempo.Client.Transport

  @recorder {:jido_connect_tempo, :tempo_req_options}
  @jira ["JIRA_SITE", "JIRA_EMAIL", "JIRA_API_TOKEN"]
  @attributes %{
    "_JclPhase_" => {"STATIC_LIST", "JCL live: phase"},
    "_JclBillable_" => {"CHECKBOX", "JCL live: billable"},
    "_JclHours_" => {"INPUT_NUMERIC", "JCL live: estimate hours"},
    "_JclAccount_" => {"ACCOUNT", "JCL live: account"}
  }
  @attribute_keys @attributes |> Map.keys() |> Enum.sort()
  @accounts %{
    "JCL-PROJECT" => {"JCL live: project account", "OPEN", false},
    "JCL-SECONDARY" => {"JCL live: second project account", "OPEN", false},
    "JCL-CLOSED" => {"JCL live: closed project account", "CLOSED", false},
    "JCL-GLOBAL" => {"JCL live: global account", "OPEN", true}
  }

  @tag env!([
         "TEMPO_API_TOKEN",
         "TEMPO_API_ORIGIN",
         "TEMPO_JIRA_PROJECT_ID",
         "TEMPO_ACCOUNT_ID" | @jira
       ])
  test "the account candidates of the test project match the seeded accounts", %{env: env} do
    token = env["TEMPO_API_TOKEN"]
    project = String.to_integer(env["TEMPO_JIRA_PROJECT_ID"])
    context = context!(env, :api_token, ["tempo.accounts.read"])
    raw = raw_test_accounts!(env, token, project)
    LiveSmoke.record(@recorder, :tempo, "accounts_for_project", transform: site_data(raw))

    result =
      ok!(
        invoke(context, :api_token, token, "tempo.account.list_for_project", %{
          project_id: project
        }),
        "the account read"
      )

    assert result.project_id == project
    accounts = Enum.filter(result.accounts, &Map.has_key?(@accounts, &1.key))

    assert accounts |> Enum.map(& &1.key) |> Enum.sort() == @accounts |> Map.keys() |> Enum.sort()

    for account <- accounts do
      {name, status, global} = @accounts[account.key]
      assert {account.name, account.status, account.global} == {name, status, global}

      direct = Map.fetch!(raw, Integer.to_string(account.id))

      assert {account.id, account.key, account.name, account.status, account.global} ==
               {direct["id"], direct["key"], direct["name"], direct["status"], direct["global"]}

      assert [link] = account.links
      assert {link.scope_type, link.scope_id} == {"PROJECT", project}
      assert link.default == (account.key == "JCL-PROJECT")
      assert if(account.global, do: link.id == 0, else: link.id > 0)
    end

    default = Enum.find(accounts, &(&1.key == "JCL-PROJECT"))
    assert Integer.to_string(default.id) == env["TEMPO_ACCOUNT_ID"]

    defaults = for account <- result.accounts, link <- account.links, link.default, do: link
    one_default? = length(defaults) == 1
    assert one_default?, "the project does not have exactly one default link"
  end

  @tag env!(["TEMPO_API_TOKEN", "TEMPO_API_ORIGIN" | @jira])
  test "an unknown account gets Tempo's not-found answer", %{env: env} do
    request = request!(env, env["TEMPO_API_TOKEN"])
    LiveSmoke.record(@recorder, :tempo, "account_not_found")

    assert {:error, %Error.ProviderError{reason: :not_found, status: 404, details: details}} =
             Transport.get(request, "/4/accounts/999999")

    assert details.message == "Invalid account"
  end

  # Needs the four test attributes, which exist only in a work-attribute
  # window; see the moduledoc.
  @tag env!(["TEMPO_OAUTH_ACCESS_TOKEN", "TEMPO_API_ORIGIN" | @jira])
  test "the work attributes match the configured time-entry form", %{env: env} do
    token = env["TEMPO_OAUTH_ACCESS_TOKEN"]
    context = context!(env, :oauth2_user, ["tempo.worklogs.read"])
    raw = raw_test_attributes!(env, token)

    required =
      case raw |> Map.values() |> Enum.map(& &1["required"]) |> Enum.uniq() do
        [required] when is_boolean(required) -> required
        _other -> flunk("the four test attributes do not share one required flag")
      end

    mode = if required, do: "required", else: "optional"
    IO.puts("work attribute window observed: #{mode}")
    LiveSmoke.record(@recorder, :tempo, "work_attributes_" <> mode, transform: site_data(%{}))

    result =
      ok!(invoke(context, :oauth2_user, token, "tempo.work_attribute.list", %{}), "the read")

    attributes = Enum.filter(result.attributes, &(&1.key in @attribute_keys))
    assert attributes |> Enum.map(& &1.key) |> Enum.sort() == @attribute_keys

    for attribute <- attributes do
      direct = raw[attribute.key]
      assert {attribute.type, attribute.name} == @attributes[attribute.key]
      assert attribute.required == required

      assert {attribute.key, attribute.name, attribute.type, attribute.required, attribute.self} ==
               {direct["key"], direct["name"], direct["type"], direct["required"], direct["self"]}
    end

    phase = Enum.find(attributes, &(&1.key == "_JclPhase_"))
    assert Enum.map(phase.values, & &1.value) == raw["_JclPhase_"]["values"]
    assert Enum.map(phase.values, & &1.label) == ["analysis", "build", "review"]
    assert Enum.all?(phase.values, &(&1.label == raw["_JclPhase_"]["names"][&1.value]))

    assert Enum.all?(attributes, &(&1.type == "STATIC_LIST" or &1.values == nil))
    refute Enum.any?(result.incomplete, &(&1.key in @attribute_keys))

    consistent? = result.complete == (result.incomplete == [])
    assert consistent?, "complete does not match the incomplete requirements"
  end

  # Needs the four test attributes; see the moduledoc. The worklog read is
  # recorded after the attribute and account reads, which are not.
  @tag env!(["TEMPO_API_TOKEN", "TEMPO_API_ORIGIN", "TEMPO_JIRA_PROJECT_ID" | @jira])
  test "the seeded worklog stores the value each attribute type takes", %{env: env} do
    token = env["TEMPO_API_TOKEN"]
    project = String.to_integer(env["TEMPO_JIRA_PROJECT_ID"])
    scopes = ["tempo.worklogs.read", "tempo.accounts.read"]
    context = context!(env, :api_token, scopes)
    day = %{from: "2026-10-01", to: "2026-10-01"}

    attributes =
      ok!(invoke(context, :api_token, token, "tempo.work_attribute.list", %{}), "the read")

    accounts =
      ok!(
        invoke(context, :api_token, token, "tempo.account.list_for_project", %{
          project_id: project
        }),
        "the account read"
      )

    LiveSmoke.record(@recorder, :tempo, "work_attribute_values", transform: site_data(%{}))
    worklogs = ok!(invoke(context, :api_token, token, "tempo.worklogs.list_own", day), "the read")

    values =
      for worklog <- worklogs.worklogs,
          value <- worklog.work_attributes,
          value.key in @attribute_keys,
          do: {worklog.tempo_worklog_id, value.key, value.value}

    assert values |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 1,
           "not exactly one worklog of October 1 carries the test attributes"

    stored = Map.new(values, fn {_id, key, value} -> {key, value} end)
    assert stored |> Map.keys() |> Enum.sort() == @attribute_keys

    phase = Enum.find(attributes.attributes, &(&1.key == "_JclPhase_"))
    assert %{label: "build"} = Enum.find(phase.values, &(&1.value == stored["_JclPhase_"]))

    IO.puts("CHECKBOX value: #{inspect(stored["_JclBillable_"])}")
    IO.puts("INPUT_NUMERIC value: #{inspect(stored["_JclHours_"])}")
    assert stored["_JclBillable_"] == "true"
    assert stored["_JclHours_"] == "1.5"

    project_account = Enum.find(accounts.accounts, &(&1.key == "JCL-PROJECT"))
    assert stored["_JclAccount_"] == project_account.key
    refute stored["_JclAccount_"] in [project_account.name, Integer.to_string(project_account.id)]

    direct =
      for worklog <- raw_worklogs!(env, token, day),
          value <- get_in(worklog, ["attributes", "values"]) || [],
          value["key"] in @attribute_keys,
          do: {worklog["tempoWorklogId"], value["key"], value["value"]}

    assert Enum.sort(values) == Enum.sort(direct)
  end

  # What the shared site returns besides the test data stays out of the
  # fixtures, in four places: work attributes other than the four test
  # attributes become neutral entries `_Other<n>_` that keep only their
  # recorded type and required flag; links of accounts outside the test
  # data are left out, and metadata.count counts the links that stay; reads
  # of those accounts are not recorded; and worklog values of other
  # attributes are left out. `test_accounts` maps the IDs of the test
  # accounts, as strings, to their direct reads.
  defp site_data(test_accounts) do
    fn
      "/4/accounts/" <> id, body ->
        if Map.has_key?(test_accounts, id), do: body, else: :skip

      "/4/account-links/project/" <> _project, %{"results" => links} = body
      when is_list(links) ->
        kept = Enum.filter(links, &Map.has_key?(test_accounts, link_account_id(&1)))

        body
        |> Map.put("results", kept)
        |> Map.update("metadata", %{}, &Map.put(&1, "count", length(kept)))

      "/4/work-attributes", %{"results" => attributes} = body when is_list(attributes) ->
        %{body | "results" => neutral_attributes(attributes)}

      "/4/worklogs/" <> _rest, %{"results" => worklogs} = body when is_list(worklogs) ->
        %{body | "results" => Enum.map(worklogs, &test_values_only/1)}

      _path, body ->
        body
    end
  end

  defp neutral_attributes(attributes) do
    attributes
    |> Enum.map_reduce(1, fn
      %{"key" => key} = attribute, n when key in @attribute_keys ->
        {attribute, n}

      attribute, n ->
        key = "_Other#{n}_"

        neutral = %{
          "key" => key,
          "name" => "Other attribute #{n}",
          "type" => attribute["type"],
          "required" => attribute["required"],
          "self" => neutral_self(attribute["self"], key)
        }

        {neutral, n + 1}
    end)
    |> elem(0)
  end

  defp neutral_self(self, key) when is_binary(self) do
    uri = URI.parse(self)
    URI.to_string(%{uri | path: "/4/work-attributes/" <> key, query: nil, fragment: nil})
  end

  defp neutral_self(_self, _key), do: nil

  defp test_values_only(%{"attributes" => %{"values" => values} = attributes} = worklog)
       when is_list(values) do
    kept = Enum.filter(values, &(&1["key"] in @attribute_keys))
    %{worklog | "attributes" => %{attributes | "values" => kept}}
  end

  defp test_values_only(worklog), do: worklog

  defp link_account_id(%{"account" => %{"self" => self}}) when is_binary(self),
    do: self |> URI.parse() |> Map.get(:path, "") |> Path.basename()

  defp link_account_id(_link), do: nil

  # The test accounts among the project's candidates, read directly,
  # outside the package and the recorder, by ID as a string.
  defp raw_test_accounts!(env, token, project) do
    %{"results" => links} =
      raw_get!(env, token, "/4/account-links/project/#{project}", includeGlobalAccounts: true)

    for link <- links,
        id = link_account_id(link),
        account = raw_get!(env, token, "/4/accounts/" <> id),
        Map.has_key?(@accounts, account["key"]),
        into: %{},
        do: {id, account}
  end

  # The four test attributes, read directly in one page, by key.
  defp raw_test_attributes!(env, token) do
    case raw_get!(env, token, "/4/work-attributes", offset: 0, limit: 1000) do
      %{"results" => results, "metadata" => metadata} when not is_map_key(metadata, "next") ->
        for %{"key" => key} = attribute <- results, key in @attribute_keys, into: %{} do
          {key, attribute}
        end

      _other ->
        flunk("the direct work attribute read did not return one complete page")
    end
  end

  defp raw_worklogs!(env, token, %{from: from, to: to}) do
    path = "/4/worklogs/user/" <> URI.encode(account_id!(env), &URI.char_unreserved?/1)

    case raw_get!(env, token, path, from: from, to: to, offset: 0, limit: 1000) do
      %{"results" => results, "metadata" => metadata} when not is_map_key(metadata, "next") ->
        results

      _other ->
        flunk("the direct worklog read did not return one complete page")
    end
  end

  # The path can name the account ID or an account of the site's other
  # data, so a failure names only the status.
  defp raw_get!(env, token, path, params \\ []) do
    case Req.get(env["TEMPO_API_ORIGIN"] <> path,
           auth: {:bearer, token},
           params: params,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} -> body
      {:ok, %{status: status}} -> flunk("a direct Tempo read got status #{status}")
      _other -> flunk("a direct Tempo read failed")
    end
  end

  defp ok!({:ok, value}, _step), do: value

  defp ok!({:error, error}, step),
    do:
      flunk(
        "#{step} failed: #{inspect(Map.get(error, :reason))}, status #{inspect(Map.get(error, :status))}"
      )

  defp invoke(%Context{connection: connection} = context, profile, token, action, input) do
    field = if profile == :api_token, do: :api_token, else: :access_token

    lease =
      CredentialLease.from_connection!(connection, %{field => token},
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
      )

    Jido.Connect.invoke(Tempo, action, input, context: context, credential_lease: lease)
  end

  defp context!(env, profile, scopes) do
    Context.new!(%{
      tenant_id: "live",
      actor: %{id: "live", type: :app_user},
      connection: connection!(env, profile, scopes)
    })
  end

  defp connection!(env, profile, scopes) do
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
      metadata: %{api_origin: env["TEMPO_API_ORIGIN"]}
    })
  end

  defp request!(env, token) do
    case Tempo.Client.Request.new(connection!(env, :api_token, []), %{api_token: token}) do
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
