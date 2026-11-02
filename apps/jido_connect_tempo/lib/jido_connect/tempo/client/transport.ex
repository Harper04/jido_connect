defmodule Jido.Connect.Tempo.Client.Transport do
  @moduledoc """
  Tempo REST v4 transport boundary.

  Both profiles send their leased token as a Bearer credential through
  `Jido.Connect.Provider.Transport.bearer_request/3`, with the connection's
  `api_origin` as base URL.

  The token never leaves that origin:

  - `get/3` accepts only a path relative to the origin and raises for an
    absolute or scheme-relative URL before any request.
  - Redirects are not followed. A 3xx response becomes a
    `Jido.Connect.Error.ProviderError`, so a `Location` on another origin
    never receives the `authorization` header.
  - Req options from `:tempo_req_options` and `:req_options`, used for
    `Req.Test` and the live smoke recorder, cannot set `:base_url`, `:url`,
    `:auth`, `:redirect` or `:redirect_trusted`.

  Automatic retries are off by default; a caller may enable them through
  `:req_options`. Failures carry `retry_after` for the host's own retry
  policy.
  """

  alias Jido.Connect.Provider.Transport
  alias Jido.Connect.Tempo.Client.{Request, Response}

  @locked_options [:base_url, :url, :auth, :redirect, :redirect_trusted]

  @doc "Builds the Bearer request for one Tempo connection."
  @spec request(Request.t(), keyword()) :: Req.Request.t()
  def request(%Request{} = request, opts \\ []) when is_list(opts) do
    req_options =
      [retry: false]
      |> Keyword.merge(Application.get_env(:jido_connect_tempo, :tempo_req_options, []))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Keyword.drop(@locked_options)
      |> Keyword.put(:redirect, false)

    Transport.bearer_request(request.api_origin, Request.token(request),
      headers: [{"accept", "application/json"}],
      req_options: req_options
    )
  end

  @doc """
  Sends a GET request for `path` and returns the decoded JSON body.

  `path` must start with a single `/`. Options: `:params` (query parameters)
  and `:req_options`.
  """
  @spec get(Request.t(), String.t(), keyword()) ::
          {:ok, map() | list()} | {:error, Jido.Connect.Error.ProviderError.t()}
  def get(%Request{} = request, path, opts \\ []) when is_binary(path) do
    validate_path!(path)

    request
    |> request(opts)
    |> Transport.request(:get, url: path, params: Keyword.get(opts, :params, []))
    |> Response.handle()
  end

  defp validate_path!("//" <> _rest), do: raise_path!()

  defp validate_path!("/" <> _rest = path) do
    case URI.parse(path) do
      %URI{scheme: nil, host: nil} -> :ok
      _uri -> raise_path!()
    end
  end

  defp validate_path!(_path), do: raise_path!()

  defp raise_path! do
    raise ArgumentError, "Tempo request paths must be relative to the connection origin"
  end
end
