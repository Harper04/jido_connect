defmodule Jido.Connect.Tempo.OAuthTest do
  use ExUnit.Case, async: false

  alias Jido.Connect.Error
  alias Jido.Connect.Tempo.{Fixture, OAuth}

  @client_secret "client-secret-under-test"
  @opts [
    client_id: "client-under-test",
    client_secret: @client_secret,
    redirect_uri: "https://host.example.com/integrations/tempo/oauth/callback"
  ]

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous = Application.fetch_env(:jido_connect_tempo, :tempo_oauth_req_options)

    Application.put_env(:jido_connect_tempo, :tempo_oauth_req_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jido_connect_tempo, :tempo_oauth_req_options, value)
        :error -> Application.delete_env(:jido_connect_tempo, :tempo_oauth_req_options)
      end
    end)
  end

  describe "authorize_url/1" do
    test "builds the encoded authorize URL" do
      url =
        OAuth.authorize_url(
          client_id: "client id/1",
          redirect_uri: "https://host.example.com/integrations/tempo/oauth/callback?x=1",
          jira_url: "https://example.atlassian.net"
        )

      assert url ==
               "https://api.tempo.io/oauth/authorize/redirect" <>
                 "?client_id=client%20id%2F1" <>
                 "&redirect_uri=https%3A%2F%2Fhost.example.com%2Fintegrations%2Ftempo%2Foauth%2Fcallback%3Fx%3D1" <>
                 "&jira_url=https%3A%2F%2Fexample.atlassian.net"
    end

    test "requires client_id, redirect_uri and jira_url" do
      valid = [
        client_id: "client",
        redirect_uri: "https://host.example.com/cb",
        jira_url: "https://example.atlassian.net"
      ]

      for key <- [:client_id, :redirect_uri, :jira_url], value <- [nil, ""] do
        opts = Keyword.put(valid, key, value)
        assert_raise Error.ConfigError, ~r/#{key}/, fn -> OAuth.authorize_url(opts) end
      end
    end
  end

  describe "exchange_code/2" do
    test "posts the form body to /oauth/token/ and keeps both tokens, expiry and scope" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert {conn.method, conn.scheme, conn.host, conn.request_path} ==
                 {"POST", :https, "api.tempo.io", "/oauth/token/"}

        assert Plug.Conn.get_req_header(conn, "content-type") == [
                 "application/x-www-form-urlencoded"
               ]

        assert URI.decode_query(Req.Test.raw_body(conn)) == %{
                 "grant_type" => "authorization_code",
                 "client_id" => "client-under-test",
                 "client_secret" => @client_secret,
                 "redirect_uri" => "https://host.example.com/integrations/tempo/oauth/callback",
                 "code" => "code-1"
               }

        Req.Test.json(conn, observed_token())
      end)

      assert {:ok, token} = OAuth.exchange_code("code-1", @opts)

      assert token == %{
               access_token: "observed-access-token-placeholder",
               refresh_token: "observed-refresh-token-placeholder",
               expires_in: 2_591_999,
               scope: String.split(observed_token()["scope"])
             }

      assert "worklogs:manage" in token.scope
    end

    test "rejects a token response without its fields and does not echo the body" do
      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, Map.delete(observed_token(), "expires_in"))
      end)

      assert {:error,
              %Error.ProviderError{
                provider: :tempo,
                reason: :invalid_response,
                details: %{missing_fields: [:expires_in]}
              } = error} = OAuth.exchange_code("code-1", @opts)

      refute inspect(error) =~ "observed-access-token-placeholder"
    end

    test "an invalid code is a normalized error without client secret or code" do
      Req.Test.expect(__MODULE__, &Fixture.respond(&1, "oauth_invalid_code"))

      assert {:error,
              %Error.ProviderError{provider: :tempo, reason: :forbidden, status: 403} = error} =
               OAuth.exchange_code("code-under-test", @opts)

      assert error.details.message == "authorization code is invalid"
      refute_secrets(error, ["code-under-test"])
    end

    # The recorded rejection with the submitted code and secret put into its
    # message, as a provider echoing its input would send it.
    test "secrets echoed in an error message are redacted" do
      Req.Test.expect(__MODULE__, fn conn ->
        Fixture.respond(conn, "oauth_invalid_code",
          body: &Map.put(&1, "message", "code code-under-test for #{@client_secret} is invalid")
        )
      end)

      assert {:error, %Error.ProviderError{} = error} =
               OAuth.exchange_code("code-under-test", @opts)

      assert error.details.message == "code [redacted] for [redacted] is invalid"
      refute_secrets(error, ["code-under-test"])
    end

    test "a token request does not follow redirects" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://collector.example.com/oauth/token/")
        |> Plug.Conn.send_resp(307, "")
      end)

      assert {:error, %Error.ProviderError{reason: :redirect_not_followed, status: 307}} =
               OAuth.exchange_code("code-1", @opts)
    end

    test "a timeout is a request error" do
      Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))

      assert {:error, %Error.ProviderError{reason: :request_error} = error} =
               OAuth.exchange_code("code-1", @opts)

      refute_secrets(error, ["code-1"])
    end

    test "requires client_id, client_secret and redirect_uri" do
      for key <- [:client_id, :client_secret, :redirect_uri] do
        error =
          assert_raise Error.ConfigError, ~r/#{key}/, fn ->
            OAuth.exchange_code("code-1", Keyword.delete(@opts, key))
          end

        refute inspect(error) =~ @client_secret
      end
    end
  end

  # No refresh response was recorded or observed: a live refresh would replace
  # the stored tokens. These tests assume the observed exchange shape, as
  # Tempo's OpenAPI says only that a refresh response "will contain a new
  # access token and a new refresh token". Its example field `token_type`
  # ("Bearer") is not read.
  describe "refresh/2" do
    test "posts the refresh form and returns both replacement tokens" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert {conn.method, conn.host, conn.request_path} ==
                 {"POST", "api.tempo.io", "/oauth/token/"}

        assert URI.decode_query(Req.Test.raw_body(conn)) == %{
                 "grant_type" => "refresh_token",
                 "client_id" => "client-under-test",
                 "client_secret" => @client_secret,
                 "redirect_uri" => "https://host.example.com/integrations/tempo/oauth/callback",
                 "refresh_token" => "stored-refresh-token"
               }

        Req.Test.json(conn, observed_token())
      end)

      assert {:ok,
              %{
                access_token: "observed-access-token-placeholder",
                refresh_token: "observed-refresh-token-placeholder",
                expires_in: 2_591_999
              }} = OAuth.refresh("stored-refresh-token", @opts)
    end

    # Tempo invalidates the old refresh token on every refresh, so a response
    # without a new one leaves the connection without a usable refresh token.
    test "a refresh response without a new refresh token is an error" do
      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, Map.delete(observed_token(), "refresh_token"))
      end)

      assert {:error,
              %Error.ProviderError{
                reason: :invalid_response,
                details: %{missing_fields: [:refresh_token]}
              } = error} = OAuth.refresh("stored-refresh-token", @opts)

      refute inspect(error) =~ "observed-access-token-placeholder"
    end

    test "an invalid refresh token is a normalized error without the token" do
      Req.Test.expect(__MODULE__, &Fixture.respond(&1, "oauth_invalid_refresh_token"))

      assert {:error, %Error.ProviderError{reason: :forbidden, status: 403} = error} =
               OAuth.refresh("stored-refresh-token", @opts)

      assert error.details.message == "refresh token is invalid"
      refute_secrets(error, ["stored-refresh-token"])
    end
  end

  defp observed_token, do: Fixture.observed!("oauth_token")["body"]

  defp refute_secrets(error, values) do
    for value <- [@client_secret | values] do
      refute inspect(error) =~ value
      refute inspect(Error.to_map(error)) =~ value
    end
  end
end
