defmodule Jido.Connect.Tempo.ListOwnWorklogsActionTest do
  use ExUnit.Case, async: false

  # `tempo.worklogs.list_own` through the runtime and through the generated
  # Jido action, against the October read that the foundation recorded:
  # 50 worklogs with a `next` link, then 5 without one.

  alias Jido.Connect
  alias Jido.Connect.{Connection, Context, CredentialLease, Error}
  alias Jido.Connect.Tempo
  alias Jido.Connect.Tempo.Actions.ListOwnWorklogs
  alias Jido.Connect.Tempo.Fixture

  @action "tempo.worklogs.list_own"
  @account "account-1"
  @api_token "tempo-api-token-272-secret"
  @access_token "tempo-oauth-token-272-secret"
  @october %{from: "2026-10-01", to: "2026-10-31"}

  defmodule RecordingClient do
    @moduledoc false

    # A provider client that reports its call and returns no worklogs.
    def list_own_worklogs(request, opts) do
      send(self(), {:list_own_worklogs, request, opts})
      {:ok, []}
    end
  end

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous = Application.fetch_env(:jido_connect_tempo, :tempo_req_options)
    Application.put_env(:jido_connect_tempo, :tempo_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jido_connect_tempo, :tempo_req_options, value)
        :error -> Application.delete_env(:jido_connect_tempo, :tempo_req_options)
      end
    end)
  end

  describe "output" do
    test "returns the own worklogs of the range as plain maps with complete true" do
      expect_pages(["worklogs_page", "worklogs_page.2"])

      assert {:ok, result} = invoke(:api_token, @october)

      assert %{
               account_id: @account,
               from: "2026-10-01",
               to: "2026-10-31",
               complete: true,
               worklogs: [first | _rest] = worklogs
             } = result

      assert length(worklogs) == 55
      refute is_struct(first)

      assert first == %{
               tempo_worklog_id: 79_097,
               author_account_id: @account,
               start_date: "2026-10-01",
               time_spent_seconds: 5400,
               issue_id: 46_097,
               description: "JCL live seed worklog: open period, first day",
               work_attributes: [],
               start_time: "09:00:00",
               start_date_time_utc: "2026-10-01T07:00:00Z",
               billable_seconds: 5400,
               created_at: "2026-10-30T19:19:07Z",
               updated_at: "2026-10-30T19:22:34Z",
               self: "https://api.tempo.io/4/worklogs/79097"
             }

      assert {:ok, _json} = Jason.encode(result)
    end

    test "the generated action reads with the OAuth profile" do
      expect_pages(["worklogs_page", "worklogs_page.2"])
      context = context(:oauth2_user)

      assert {:ok, %{account_id: @account, complete: true, worklogs: [_ | _]}} =
               ListOwnWorklogs.run(@october, %{
                 integration_context: context,
                 credential_lease: lease(context)
               })
    end

    test "the account comes from subject.account_id through the provider client seam" do
      context = context(:api_token, account_id: "557058:own-account")

      assert {:ok, %{account_id: "557058:own-account", worklogs: [], complete: true} = result} =
               ListOwnWorklogs.run(@october, %{
                 integration_context: context,
                 credential_lease: lease(context),
                 provider_client: RecordingClient
               })

      assert result.from == "2026-10-01" and result.to == "2026-10-31"
      assert_received {:list_own_worklogs, request, opts}
      assert request.account_id == "557058:own-account"
      assert opts == [from: "2026-10-01", to: "2026-10-31"]
    end
  end

  describe "gates before HTTP" do
    setup do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, :requested)
        Fixture.respond(conn, "worklogs_page")
      end)

      :ok
    end

    test "no input selects another account" do
      for extra <- [
            %{account_id: "account-2"},
            %{author_account_id: "account-2"},
            %{accountId: "account-2"},
            %{updated_from: "2026-10-30"}
          ] do
        assert {:error, %Error.ValidationError{reason: :input}} =
                 invoke(:api_token, Map.merge(@october, extra))
      end

      refute_received :requested
    end

    test "a missing or invalid range fails validation" do
      for input <- [
            %{from: "2026-10-01"},
            %{to: "2026-10-31"},
            %{from: "2026-10-31", to: "2026-10-01"},
            %{from: "2026-10-01T00:00:00Z", to: "2026-10-31"},
            %{from: "2026-10-01", to: "31.10.2026"}
          ] do
        assert {:error, %Error.ValidationError{}} = invoke(:api_token, input)
      end

      refute_received :requested
    end

    test "a missing tempo.worklogs.read grant stops the call" do
      assert {:error,
              %Error.AuthError{reason: :missing_scopes, missing_scopes: ["tempo.worklogs.read"]}} =
               invoke(:api_token, @october,
                 scopes: ["tempo.periods.read", "tempo.worklogs.write"]
               )

      refute_received :requested
    end

    test "an expired lease stops the call" do
      context = context(:api_token)
      expired = lease(context, expires_at: DateTime.add(DateTime.utc_now(), -1, :second))

      assert {:error, %Error.AuthError{}} =
               Connect.invoke(Tempo, @action, @october,
                 context: context,
                 credential_lease: expired
               )

      refute_received :requested
    end

    test "a lease of another connection stops the call" do
      context = context(:api_token)
      other = context(:api_token, connection_id: "tempo_conn_other")

      assert {:error, %Error.AuthError{}} =
               Connect.invoke(Tempo, @action, @october,
                 context: context,
                 credential_lease: lease(other)
               )

      refute_received :requested
    end

    test "a lease without the profile's token field stops the call" do
      context = context(:oauth2_user)
      lease = lease(context, fields: %{api_token: @api_token})

      assert {:error, %Error.AuthError{reason: :tempo_credentials_required}} =
               Connect.invoke(Tempo, @action, @october, context: context, credential_lease: lease)

      refute_received :requested
    end

    test "a connection without subject.account_id stops the call" do
      context = context(:api_token, account_id: nil)

      assert {:error, %Error.AuthError{reason: :tempo_account_id_required}} =
               Connect.invoke(Tempo, @action, @october,
                 context: context,
                 credential_lease: lease(context)
               )

      refute_received :requested
    end
  end

  describe "errors" do
    test "a failed later page returns no worklogs and no credentials" do
      Req.Test.expect(__MODULE__, 2, fn conn ->
        case URI.decode_query(conn.query_string)["offset"] do
          "0" -> Fixture.respond(conn, "worklogs_page")
          "50" -> Fixture.respond(conn, "worklogs_page.2", status: 500)
        end
      end)

      assert {:error, %Error.ProviderError{provider: :tempo, reason: :server_error} = error} =
               invoke(:oauth2_user, @october)

      for text <- [inspect(error), inspect(Error.to_map(error)), Exception.message(error)],
          secret <- [@api_token, @access_token, "JCL live seed worklog"] do
        refute text =~ secret
      end
    end
  end

  defp expect_pages(names) do
    Req.Test.expect(__MODULE__, length(names), fn conn ->
      offset = String.to_integer(URI.decode_query(conn.query_string)["offset"])
      Fixture.respond(conn, Enum.at(names, div(offset, 50)))
    end)
  end

  defp invoke(profile, input, opts \\ []) do
    context = context(profile, Keyword.take(opts, [:scopes]))
    Connect.invoke(Tempo, @action, input, context: context, credential_lease: lease(context))
  end

  defp context(profile, opts \\ []) do
    connection =
      Connection.new!(%{
        id: Keyword.get(opts, :connection_id, "tempo_conn_1"),
        provider: :tempo,
        profile: profile,
        tenant_id: "tenant_1",
        owner_type: :app_user,
        owner_id: "user_1",
        subject: %{account_id: Keyword.get(opts, :account_id, @account)},
        status: :connected,
        scopes: Keyword.get(opts, :scopes, ["tempo.worklogs.read"]),
        metadata: %{api_origin: "https://api.us.tempo.io"}
      })

    Context.new!(%{
      tenant_id: "tenant_1",
      actor: %{id: "user_1", type: :app_user},
      connection: connection
    })
  end

  defp lease(%Context{connection: connection}, opts \\ []) do
    fields =
      Keyword.get_lazy(opts, :fields, fn ->
        case connection.profile do
          :api_token -> %{api_token: @api_token}
          :oauth2_user -> %{access_token: @access_token}
        end
      end)

    CredentialLease.from_connection!(connection, fields,
      expires_at:
        Keyword.get_lazy(opts, :expires_at, fn -> DateTime.add(DateTime.utc_now(), 60) end)
    )
  end
end
