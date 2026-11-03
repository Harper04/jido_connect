defmodule Jido.Connect.Slack.OAuth do
  @moduledoc """
  Slack OAuth v2 helpers.

  Hosts own callback state, durable installation storage, and credential
  storage. This module only builds URLs, exchanges codes, and shapes credential
  leases.
  """

  alias Jido.Connect
  alias Jido.Connect.{Data, Error, Scope}
  alias Jido.Connect.OAuth, as: CoreOAuth
  alias Jido.Connect.Slack.Client

  @authorize_url "https://slack.com/oauth/v2/authorize"
  @token_url "https://slack.com/api/oauth.v2.access"

  @doc """
  Builds Slack's authorize URL.

  `:scopes` (or `:scope`) are the bot scopes and go to Slack as `scope`.
  `:user_scope` lists the scopes of a user token for the person who
  authorizes, such as `["channels:history", "groups:history", "im:history",
  "mpim:history"]`, and goes to Slack as `user_scope`. Without `:user_scope`,
  or with an empty list, the URL has no `user_scope`.
  """
  def authorize_url(opts) when is_list(opts) do
    client_id = CoreOAuth.fetch_required!(opts, :client_id, "SLACK_CLIENT_ID")
    redirect_uri = Keyword.fetch!(opts, :redirect_uri)
    state = Keyword.fetch!(opts, :state)

    scopes =
      opts
      |> Keyword.get(:scopes, Keyword.get(opts, :scope, default_scopes()))
      |> Scope.encode(separator: ",")

    CoreOAuth.authorize_url(@authorize_url, %{
      client_id: client_id,
      redirect_uri: redirect_uri,
      scope: scopes,
      user_scope: opts |> Keyword.get(:user_scope) |> encode_scopes(),
      state: state
    })
  end

  defp encode_scopes(nil), do: nil
  defp encode_scopes(scopes), do: Scope.encode(scopes, separator: ",")

  def exchange_code(code, opts \\ []) when is_binary(code) and is_list(opts) do
    client_id = CoreOAuth.fetch_required!(opts, :client_id, "SLACK_CLIENT_ID")
    client_secret = CoreOAuth.fetch_required!(opts, :client_secret, "SLACK_CLIENT_SECRET")

    CoreOAuth.req(
      base_url: Keyword.get(opts, :base_url, @token_url),
      auth: {:basic, "#{client_id}:#{client_secret}"},
      headers: [
        {"accept", "application/json"}
      ]
    )
    |> Req.merge(Application.get_env(:jido_connect_slack, :slack_oauth_req_options, []))
    |> Req.post(
      form: %{
        code: code,
        redirect_uri: Keyword.get(opts, :redirect_uri)
      }
    )
    |> handle_token_response()
  end

  def bot_credential_lease(token, context, opts \\ []) when is_map(token) do
    connection_id =
      Keyword.get(opts, :connection_id) ||
        "slack-team-#{get_in(token, [:team, "id"]) || get_in(token, [:team, :id])}"

    expires_at = Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 3600, :second))
    scopes = Map.get(token, :scope, [])

    fields = %{
      access_token: Map.fetch!(token, :access_token),
      slack_client: Keyword.get(opts, :slack_client, Client)
    }

    metadata = %{
      context: context,
      app_id: Map.get(token, :app_id),
      bot_user_id: Map.get(token, :bot_user_id),
      team: Map.get(token, :team),
      enterprise: Map.get(token, :enterprise),
      scopes: scopes
    }

    lease_opts = [
      connection_id: connection_id,
      expires_at: expires_at,
      scopes: scopes,
      metadata: metadata
    ]

    case Keyword.get(opts, :connection) do
      %Connect.Connection{} = connection ->
        Connect.CredentialLease.from_connection(connection, fields, lease_opts)

      _other ->
        Connect.CredentialLease.new(%{
          connection_id: connection_id,
          provider: :slack,
          profile: Keyword.get(opts, :profile, :bot),
          tenant_id: Data.get(context, :tenant_id),
          owner_type: Keyword.get(opts, :owner_type, :tenant),
          owner_id:
            Keyword.get(opts, :owner_id) ||
              get_in(token, [:team, "id"]) ||
              get_in(token, [:team, :id]),
          scopes: scopes,
          expires_at: expires_at,
          fields: fields,
          metadata: metadata
        })
    end
  end

  defp handle_token_response({:ok, %{status: status, body: %{"ok" => true} = body}})
       when status in 200..299 do
    with access_token when is_binary(access_token) <- Data.get(body, "access_token") do
      {:ok,
       %{
         access_token: access_token,
         token_type: Data.get(body, "token_type"),
         scope: Data.get(body, "scope") |> Scope.parse(),
         bot_user_id: Data.get(body, "bot_user_id"),
         app_id: Data.get(body, "app_id"),
         team: Data.get(body, "team") || %{},
         enterprise: Data.get(body, "enterprise")
       }}
    else
      _other ->
        invalid_success_response(body)
    end
  end

  defp handle_token_response({:ok, %{status: status, body: %{"ok" => false} = body}}) do
    {:error,
     Error.provider("Slack OAuth exchange failed",
       provider: :slack,
       status: status,
       reason: Data.get(body, "error"),
       details: %{body: body}
     )}
  end

  defp handle_token_response({:ok, %{status: status, body: body}}) do
    {:error,
     Error.provider("Slack OAuth HTTP request failed",
       provider: :slack,
       status: status,
       reason: :http_error,
       details: %{body: body}
     )}
  end

  defp handle_token_response({:error, reason}) do
    {:error,
     Error.provider("Slack OAuth request failed",
       provider: :slack,
       reason: :request_error,
       details: %{reason: reason}
     )}
  end

  defp invalid_success_response(body) do
    {:error,
     Error.provider("Slack OAuth response was invalid",
       provider: :slack,
       reason: :invalid_response,
       details: %{body: body}
     )}
  end

  defp default_scopes, do: ["channels:read", "chat:write", "reactions:write"]
end
