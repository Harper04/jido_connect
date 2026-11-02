defmodule Jido.Connect.Tempo.OAuth do
  @moduledoc """
  Tempo OAuth 2.0 helpers for the `:oauth2_user` profile.

  The host owns the callback route, its session binding, token storage and
  refresh scheduling. This module builds the authorize URL and posts the
  code exchange and the refresh to Tempo's token endpoint, as described in
  the Tempo REST v4 OpenAPI document (read 2026-10-30):

  - `authorize_url/1`: `https://api.tempo.io/oauth/authorize/redirect` with
    URL-encoded `client_id`, `redirect_uri` and `jira_url`.
  - `exchange_code/2` and `refresh/2`: form posts of `grant_type`,
    `client_id`, `client_secret`, `redirect_uri` and `code` or
    `refresh_token` to `https://api.tempo.io/oauth/token/`.

  Both return `access_token`, `refresh_token`, `expires_in` and `scope`, the
  granted Tempo scopes as a list. A refresh replaces both tokens: Tempo
  invalidates the old access and refresh token, so the host must store both
  new tokens before it uses either. A response without a new refresh token
  is an error. The token response has no Atlassian account ID; the host
  records `connection.subject.account_id` from Jira
  `GET /rest/api/3/myself`.

  Rejections and transport failures are `Jido.Connect.Error.ProviderError`s
  normalized like API failures (Tempo rejects an invalid code or refresh
  token with 403). They never contain the client secret, the code or a
  token. Token requests do not follow redirects. Req options for tests come
  from `:tempo_oauth_req_options`.
  """

  alias Jido.Connect.{Error, Scope}
  alias Jido.Connect.OAuth, as: CoreOAuth
  alias Jido.Connect.Tempo.Client.Response

  @origin "https://api.tempo.io"
  @authorize_url @origin <> "/oauth/authorize/redirect"
  @token_path "/oauth/token/"
  @locked_options [:base_url, :url, :auth, :redirect, :redirect_trusted]

  @type token :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          expires_in: pos_integer(),
          scope: [String.t()]
        }

  @doc """
  Builds the Tempo authorize URL.

  Requires `:client_id`, `:redirect_uri` and `:jira_url`, the site URL such
  as `https://<site>.atlassian.net`. Raises `Jido.Connect.Error.ConfigError`
  for a missing or blank option.
  """
  @spec authorize_url(keyword()) :: String.t()
  def authorize_url(opts) when is_list(opts) do
    query =
      URI.encode_query(
        [
          client_id: required!(opts, :client_id),
          redirect_uri: required!(opts, :redirect_uri),
          jira_url: required!(opts, :jira_url)
        ],
        :rfc3986
      )

    @authorize_url <> "?" <> query
  end

  @doc """
  Exchanges an authorization code for an access and a refresh token.

  Requires `:client_id`, `:client_secret` and `:redirect_uri`.
  """
  @spec exchange_code(String.t(), keyword()) :: {:ok, token()} | {:error, Error.ProviderError.t()}
  def exchange_code(code, opts) when is_binary(code) and is_list(opts) do
    request_token([grant_type: "authorization_code", code: code], code, opts)
  end

  @doc """
  Exchanges a refresh token for a new access and refresh token.

  Requires `:client_id`, `:client_secret` and `:redirect_uri`. The refresh
  token passed in is invalid afterwards, whatever the result.
  """
  @spec refresh(String.t(), keyword()) :: {:ok, token()} | {:error, Error.ProviderError.t()}
  def refresh(refresh_token, opts) when is_binary(refresh_token) and is_list(opts) do
    request_token(
      [grant_type: "refresh_token", refresh_token: refresh_token],
      refresh_token,
      opts
    )
  end

  defp request_token([grant_type | grant], grant_secret, opts) do
    client_secret = required!(opts, :client_secret)

    form =
      [
        grant_type,
        client_id: required!(opts, :client_id),
        client_secret: client_secret,
        redirect_uri: required!(opts, :redirect_uri)
      ] ++ grant

    [base_url: @origin]
    |> CoreOAuth.req()
    |> Req.merge(req_options())
    |> Req.post(url: @token_path, form: form)
    |> token_response()
    |> redact([client_secret, grant_secret])
  end

  defp req_options do
    [retry: false]
    |> Keyword.merge(Application.get_env(:jido_connect_tempo, :tempo_oauth_req_options, []))
    |> Keyword.drop(@locked_options)
    |> Keyword.put(:redirect, false)
  end

  defp token_response({:ok, %{status: status, body: %{} = body}}) when status in 200..299 do
    token = %{
      access_token: body["access_token"],
      refresh_token: body["refresh_token"],
      expires_in: body["expires_in"],
      scope: body["scope"]
    }

    case Enum.reject([:access_token, :refresh_token, :expires_in], &valid?(&1, token[&1])) do
      [] ->
        {:ok, %{token | scope: Scope.parse(token.scope)}}

      missing ->
        Response.invalid_response("Tempo OAuth token response was invalid", nil,
          status: status,
          details: %{missing_fields: missing}
        )
    end
  end

  defp token_response(response) do
    Response.handle(response, message: "Tempo OAuth token request failed")
  end

  defp valid?(:expires_in, value), do: is_integer(value) and value > 0
  defp valid?(_field, value), do: is_binary(value) and value != ""

  defp redact(
         {:error, %Error.ProviderError{details: %{message: message} = details} = error},
         secrets
       )
       when is_binary(message) do
    message =
      secrets
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce(message, &String.replace(&2, &1, "[redacted]"))

    {:error, %{error | details: %{details | message: message}}}
  end

  defp redact(result, _secrets), do: result

  defp required!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" ->
        value

      _missing ->
        raise Error.config("Tempo OAuth requires #{key}", key: key)
    end
  end
end
