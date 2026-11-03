defmodule Jido.Connect.Slack.OAuthTest do
  use ExUnit.Case, async: false

  alias Jido.Connect
  alias Jido.Connect.Error
  alias Jido.Connect.Slack.OAuth
  alias Jido.Connect.Slack.TestSupport.SyntheticFixture

  setup {Req.Test, :verify_on_exit!}

  setup do
    Application.put_env(:jido_connect_slack, :slack_oauth_req_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn ->
      Application.delete_env(:jido_connect_slack, :slack_oauth_req_options)
    end)
  end

  test "builds authorize URL" do
    url =
      OAuth.authorize_url(
        client_id: "client",
        redirect_uri: "https://demo.test/integrations/slack/oauth/callback",
        scopes: ["channels:read", "chat:write"],
        state: "state"
      )

    uri = URI.parse(url)
    params = URI.decode_query(uri.query)

    assert uri.scheme == "https"
    assert uri.host == "slack.com"
    assert uri.path == "/oauth/v2/authorize"
    assert params["client_id"] == "client"
    assert params["redirect_uri"] == "https://demo.test/integrations/slack/oauth/callback"
    assert params["scope"] == "channels:read,chat:write"
    assert params["state"] == "state"
    refute Map.has_key?(params, "user_scope")
  end

  test "sends user scopes as user_scope beside the bot scopes" do
    opts = [
      client_id: "client",
      redirect_uri: "https://demo.test/integrations/slack/oauth/callback",
      scopes: ["channels:read", "chat:write"],
      state: "state"
    ]

    without = OAuth.authorize_url(opts)

    url =
      OAuth.authorize_url(
        opts ++
          [user_scope: ["channels:history", "groups:history", "im:history", "mpim:history"]]
      )

    params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert params == %{
             "client_id" => "client",
             "redirect_uri" => "https://demo.test/integrations/slack/oauth/callback",
             "scope" => "channels:read,chat:write",
             "state" => "state",
             "user_scope" => "channels:history,groups:history,im:history,mpim:history"
           }

    assert Map.delete(params, "user_scope") ==
             without |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert OAuth.authorize_url(opts ++ [user_scope: []]) == without
    assert OAuth.authorize_url(opts ++ [user_scope: nil]) == without
  end

  # The oauth.v2.access responses are synthetic: written from Slack's
  # documentation, since recording one needs the app's client secret. Their
  # sources are named in test/fixtures/slack/synthetic.
  test "exchanges a code for the bot credential of a bot-only installation" do
    stub_oauth("oauth_v2_access_bot_only")

    assert {:ok, token} = exchange("code")

    assert_received {:oauth_request, "POST", ["Basic " <> _], form}
    assert form == %{"code" => "code", "redirect_uri" => "https://demo.test/callback"}

    assert token == %{
             access_token: "xoxb-synthetic-bot",
             token_type: "bot",
             scope: ["commands", "incoming-webhook"],
             bot_user_id: "U0KRQLJ9H",
             app_id: "A0KRD7HC3",
             team: %{"id" => "T9TK3CUKW"},
             enterprise: nil
           }
  end

  test "keeps the authorizing user's token from authed_user beside the bot credential" do
    stub_oauth("oauth_v2_access_bot_and_user")

    assert {:ok, token} = exchange("code")

    assert %{
             access_token: "xoxb-synthetic-bot",
             token_type: "bot",
             scope: ["commands", "incoming-webhook"],
             bot_user_id: "U0KRQLJ9H",
             app_id: "A0KRD7HC3",
             team: %{"id" => "T9TK3CUKW", "name" => "Slack Softball Team"},
             enterprise: %{"id" => "E12345678", "name" => "slack-sports"}
           } = token

    assert token.authed_user == %{
             id: "U1234",
             access_token: "xoxp-synthetic-user",
             token_type: "user",
             scope: ["chat:write"]
           }
  end

  test "a response without authed_user yields the bot credential only" do
    stub_oauth("oauth_v2_access_without_authed_user")

    assert {:ok, token} = exchange("code")

    assert token == %{
             access_token: "xoxb-synthetic-bot",
             token_type: "bot",
             scope: ["commands", "incoming-webhook"],
             bot_user_id: "U0KRQLJ9H",
             app_id: "A0KRD7HC3",
             team: %{"id" => "T9TK3CUKW", "name" => "Slack Softball Team"},
             enterprise: %{"id" => "E12345678", "name" => "slack-sports"}
           }
  end

  test "keeps the refresh token and expiry of a rotating user token" do
    stub_oauth("oauth_v2_access_token_rotation")
    before = DateTime.utc_now()

    assert {:ok, %{access_token: "xoxe.xoxb-synthetic-bot", authed_user: user}} =
             exchange("code")

    assert %{
             id: "U1234",
             access_token: "xoxe.xoxp-synthetic-user",
             token_type: "user",
             scope: ["chat:write"],
             refresh_token: "xoxe-synthetic-user-refresh",
             expires_in: 43_200,
             expires_at: %DateTime{} = expires_at
           } = user

    assert DateTime.diff(expires_at, before) in 43_200..43_202
  end

  test "a user-only response yields the user credential without a bot credential" do
    stub_oauth("oauth_v2_access_user_only")

    assert {:ok, token} = exchange("code")

    assert token == %{
             app_id: "A0118NQPZZC",
             team: %{"id" => "T024BE7LD"},
             enterprise: nil,
             authed_user: %{
               id: "U065VRX1T0",
               access_token: "xoxp-synthetic-user",
               token_type: "user",
               scope: ["identity.basic", "identity.email", "identity.avatar", "identity.team"]
             }
           }
  end

  test "normalizes Slack OAuth API and HTTP errors" do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/api-error"} = conn ->
        Req.Test.json(conn, SyntheticFixture.body!("oauth_v2_access_invalid_client_id"))

      conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{error: "unavailable"})
    end)

    assert {:error,
            %Error.ProviderError{
              provider: :slack,
              reason: "invalid_client_id",
              status: 200
            }} =
             OAuth.exchange_code("bad",
               client_id: "client",
               client_secret: "secret",
               base_url: "https://slack.test/api-error"
             )

    assert {:error,
            %Error.ProviderError{
              provider: :slack,
              reason: :http_error,
              status: 503,
              details: %{body_summary: %{type: :map, keys: ["error"]}}
            }} =
             OAuth.exchange_code("bad",
               client_id: "client",
               client_secret: "secret",
               base_url: "https://slack.test/http-error"
             )
  end

  # Derived from the bot-only response: without its access token it holds
  # no token at all, since its authed_user has only an ID.
  test "normalizes successful token responses without any token" do
    body = SyntheticFixture.body!("oauth_v2_access_bot_only") |> Map.delete("access_token")
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, body))

    assert {:error,
            %Error.ProviderError{
              provider: :slack,
              reason: :invalid_response,
              details: %{body_summary: %{type: :map, keys: keys}}
            }} = exchange("code")

    assert Enum.sort(keys) == body |> Map.keys() |> Enum.sort()
  end

  test "builds a redacted credential lease from a bot token response" do
    token = %{
      access_token: "xoxb-token",
      bot_user_id: "U123",
      app_id: "A123",
      scope: ["channels:read", "chat:write"],
      team: %{"id" => "T123", "name" => "Demo"}
    }

    assert {:ok, %Connect.CredentialLease{} = lease} =
             OAuth.bot_credential_lease(token, %{tenant_id: "tenant_1"},
               connection_id: "slack-team-T123"
             )

    assert lease.connection_id == "slack-team-T123"
    assert lease.provider == :slack
    assert lease.profile == :bot
    assert lease.tenant_id == "tenant_1"
    assert lease.owner_type == :tenant
    assert lease.owner_id == "T123"
    assert lease.scopes == ["channels:read", "chat:write"]
    assert lease.fields.access_token == "xoxb-token"
    assert lease.fields.slack_client == Jido.Connect.Slack.Client
    refute inspect(lease) =~ "xoxb-token"
  end

  defp stub_oauth(name) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      authorization = Plug.Conn.get_req_header(conn, "authorization")
      send(test_pid, {:oauth_request, conn.method, authorization, URI.decode_query(body)})
      Req.Test.json(conn, SyntheticFixture.body!(name))
    end)
  end

  defp exchange(code) do
    OAuth.exchange_code(code,
      client_id: "client",
      client_secret: "secret",
      redirect_uri: "https://demo.test/callback",
      base_url: "https://slack.test"
    )
  end
end
