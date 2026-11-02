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
  @channel "C0CEEB41FU0"
  @thread_ts "1793371034.447499"
  @link "https://example.com/jido-connect/delivery-check"

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

  describe "slack.message.post" do
    test "a thread reply sends the exact text with its link, a string thread_ts and reply_broadcast false" do
      %{"ts" => ts, "message" => %{"text" => text} = message} =
        LiveSmoke.fixture!(:slack, "chat_post_message_thread_reply")

      assert byte_size(text) > 512
      assert text =~ "<#{@link}|open the delivery check>"

      expect_fixture("chat_post_message_thread_reply")

      assert {:ok, output} =
               Connect.invoke(
                 Jido.Connect.Slack,
                 "slack.message.post",
                 %{channel: @channel, text: text, thread_ts: @thread_ts},
                 runtime(["chat:write"])
               )

      assert_received {:slack_request, "POST", "/api/chat.postMessage", body}

      assert body == %{
               "channel" => @channel,
               "text" => text,
               "thread_ts" => @thread_ts,
               "reply_broadcast" => false
             }

      assert output == %{channel: @channel, ts: ts, message: message}
      assert %{"thread_ts" => @thread_ts} = message
      refute Map.has_key?(message, "subtype")
    end

    test "a text-only post sends reply_broadcast false and no thread_ts" do
      %{"ts" => ts, "message" => %{"text" => text} = message} =
        LiveSmoke.fixture!(:slack, "chat_post_message_channel")

      expect_fixture("chat_post_message_channel")

      assert {:ok, output} =
               Connect.invoke(
                 Jido.Connect.Slack,
                 "slack.message.post",
                 %{channel: @channel, text: text},
                 runtime(["chat:write"])
               )

      assert_received {:slack_request, "POST", "/api/chat.postMessage", body}
      assert body == %{"channel" => @channel, "text" => text, "reply_broadcast" => false}
      assert output == %{channel: @channel, ts: ts, message: message}
    end

    test "posting needs chat:write and no history or conversation-open scope" do
      other_scopes = [
        "channels:history",
        "groups:history",
        "im:history",
        "mpim:history",
        "im:write",
        "mpim:write"
      ]

      %{"message" => %{"text" => text}} = LiveSmoke.fixture!(:slack, "chat_post_message_channel")
      input = %{channel: @channel, text: text}

      assert {:error,
              %Connect.Error.AuthError{reason: :missing_scopes, missing_scopes: ["chat:write"]}} =
               Connect.invoke(
                 Jido.Connect.Slack,
                 "slack.message.post",
                 input,
                 runtime(other_scopes)
               )

      refute_received {:slack_request, _method, _path, _body}
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
