defmodule Jido.Connect.Slack.OAuthTest do
  use ExUnit.Case, async: false

  alias Jido.Connect
  alias Jido.Connect.Error
  alias Jido.Connect.Slack.OAuth

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

  test "exchanges code for bot token" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert ["Basic " <> _] = Plug.Conn.get_req_header(conn, "authorization")

      Req.Test.json(conn, %{
        ok: true,
        access_token: "xoxb-token",
        token_type: "bot",
        scope: "channels:read,chat:write",
        bot_user_id: "U123",
        app_id: "A123",
        team: %{id: "T123", name: "Demo"}
      })
    end)

    assert {:ok, token} =
             OAuth.exchange_code("code",
               client_id: "client",
               client_secret: "secret",
               redirect_uri: "https://demo.test/callback",
               base_url: "https://slack.test"
             )

    assert token.access_token == "xoxb-token"
    assert token.scope == ["channels:read", "chat:write"]
    assert token.team == %{"id" => "T123", "name" => "Demo"}
  end

  test "normalizes Slack OAuth API and HTTP errors" do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/api-error"} = conn ->
        Req.Test.json(conn, %{ok: false, error: "bad_redirect_uri"})

      conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{error: "unavailable"})
    end)

    assert {:error,
            %Error.ProviderError{
              provider: :slack,
              reason: "bad_redirect_uri",
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

  test "normalizes malformed successful token responses" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{ok: true, token_type: "bot"})
    end)

    assert {:error,
            %Error.ProviderError{
              provider: :slack,
              reason: :invalid_response,
              details: %{body_summary: %{type: :map, keys: ["ok", "token_type"]}}
            }} =
             OAuth.exchange_code("code",
               client_id: "client",
               client_secret: "secret",
               base_url: "https://slack.test"
             )
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
end
