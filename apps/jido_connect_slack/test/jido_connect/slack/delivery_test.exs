defmodule Jido.Connect.Slack.DeliveryTest do
  use ExUnit.Case, async: false

  alias Jido.Connect
  alias Jido.Connect.TestSupport.LiveSmoke

  # Client modules that report their use and pass the call on to the package
  # client, so the response still comes from the recording.
  defmodule ContextClient do
    def open_conversation(params, token) do
      send(self(), {:client, __MODULE__})
      Jido.Connect.Slack.Client.open_conversation(params, token)
    end
  end

  defmodule LeaseClient do
    def open_conversation(params, token) do
      send(self(), {:client, __MODULE__})
      Jido.Connect.Slack.Client.open_conversation(params, token)
    end
  end

  # Recorded from the test workspace with the bot token.
  @authorizing_user "U0CDPFT1RDJ"
  @second_user "U0CDEL6734M"
  @dm "D0CD4G48UFR"
  @mpim "C0CDELYPYKF"

  setup {Req.Test, :verify_on_exit!}

  setup do
    Application.put_env(:jido_connect_slack, :slack_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:jido_connect_slack, :slack_req_options) end)
  end

  describe "slack.conversation.open" do
    test "a lease without slack_client reaches conversations.open with the supplied user" do
      expect_fixture("conversations_open_im")

      assert {:ok, %{channel: @dm, conversation: %{id: @dm}}} =
               Connect.invoke(
                 Jido.Connect.Slack,
                 "slack.conversation.open",
                 %{users: [@authorizing_user]},
                 runtime(["im:write"])
               )

      assert_received {:slack_request, "POST", "/api/conversations.open", body}

      assert body == %{
               "users" => @authorizing_user,
               "return_im" => false,
               "prevent_creation" => false
             }
    end

    test "a context provider_client goes before the lease's slack_client" do
      input = %{users: [@authorizing_user]}

      expect_fixture("conversations_open_im")

      assert {:ok, %{channel: @dm}} =
               Connect.invoke(
                 Jido.Connect.Slack,
                 "slack.conversation.open",
                 input,
                 runtime(["im:write"], %{slack_client: LeaseClient}) ++
                   [provider_client: ContextClient]
               )

      assert_received {:client, ContextClient}
      refute_received {:client, LeaseClient}

      expect_fixture("conversations_open_im")

      assert {:ok, %{channel: @dm}} =
               Connect.invoke(
                 Jido.Connect.Slack,
                 "slack.conversation.open",
                 input,
                 runtime(["im:write"], %{slack_client: LeaseClient})
               )

      assert_received {:client, LeaseClient}
      refute_received {:client, ContextClient}
    end

    test "one user needs im:write and opens the DM" do
      input = %{users: [@authorizing_user]}

      assert {:error,
              %Connect.Error.AuthError{reason: :missing_scopes, missing_scopes: ["im:write"]}} =
               Connect.invoke(
                 Jido.Connect.Slack,
                 "slack.conversation.open",
                 input,
                 runtime(["mpim:write"])
               )

      refute_received {:slack_request, _method, _path, _body}

      expect_fixture("conversations_open_im")

      assert {:ok, %{channel: @dm}} =
               Connect.invoke(
                 Jido.Connect.Slack,
                 "slack.conversation.open",
                 input,
                 runtime(["im:write"])
               )

      assert_received {:slack_request, "POST", "/api/conversations.open",
                       %{"users" => @authorizing_user}}
    end

    test "two users need mpim:write and open the group DM with both IDs" do
      input = %{users: [@authorizing_user, @second_user]}

      assert {:error,
              %Connect.Error.AuthError{reason: :missing_scopes, missing_scopes: ["mpim:write"]}} =
               Connect.invoke(
                 Jido.Connect.Slack,
                 "slack.conversation.open",
                 input,
                 runtime(["im:write"])
               )

      refute_received {:slack_request, _method, _path, _body}

      expect_fixture("conversations_open_mpim")

      assert {:ok, %{channel: @mpim, conversation: %{id: @mpim, is_mpim: true, is_im: false}}} =
               Connect.invoke(
                 Jido.Connect.Slack,
                 "slack.conversation.open",
                 input,
                 runtime(["mpim:write"])
               )

      assert_received {:slack_request, "POST", "/api/conversations.open", body}

      assert body == %{
               "users" => "#{@authorizing_user},#{@second_user}",
               "return_im" => false,
               "prevent_creation" => false
             }
    end
  end

  defp expect_fixture(name) do
    test_pid = self()

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:slack_request, conn.method, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, LiveSmoke.fixture!(:slack, name))
    end)
  end

  defp runtime(scopes, fields \\ %{}) do
    connection =
      Connect.Connection.new!(%{
        id: "slack-bot",
        provider: :slack,
        profile: :bot,
        tenant_id: "tenant-1",
        owner_type: :tenant,
        owner_id: "T0CEE692400",
        status: :connected,
        scopes: scopes
      })

    context =
      Connect.Context.new!(%{
        tenant_id: "tenant-1",
        actor: %{id: "user-1", type: :user},
        connection: connection
      })

    lease =
      Connect.CredentialLease.new!(%{
        connection_id: connection.id,
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
        scopes: scopes,
        fields: Map.put(fields, :access_token, "token")
      })

    [context: context, credential_lease: lease]
  end
end
