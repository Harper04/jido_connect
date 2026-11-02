defmodule Jido.Connect.Tempo.Client.Response do
  @moduledoc """
  Tempo REST v4 success and error response handling.

  Every failure becomes a `Jido.Connect.Error.ProviderError` with
  `provider: :tempo`. HTTP failures carry the status, a reason derived from
  it and `details.retry_after` from an integer `Retry-After` header:

  | Status | Reason |
  | --- | --- |
  | 3xx | `:redirect_not_followed` |
  | 400 | `:bad_request` |
  | 401 | `:unauthorized` |
  | 403 | `:forbidden` |
  | 404 | `:not_found` |
  | 429 | `:rate_limited` |
  | 5xx | `:server_error` |
  | other | `:http_error` |

  `details.message` is Tempo's error text from the recorded body form
  `{"errors": [{"message": ...}]}`. Tempo answers 401, and 404 for an unknown
  route, without a JSON body; those keep only the body size. A 2xx response
  without a JSON object or list is `:invalid_response`; a transport failure,
  such as a timeout, is `:request_error` with the reason code in
  `details.reason`. Raw bodies are reduced to a value-free summary.

  This module decodes JSON bodies itself; the Tempo requests turn Req's
  decoding off. An error response whose JSON body is malformed therefore
  keeps its status, reason and `retry_after`, with only the body size.
  """

  alias Jido.Connect.Error
  alias Jido.Connect.Provider.Transport

  @message "Tempo API request failed"

  @doc """
  Returns the decoded JSON body of a successful response or a normalized error.

  Options: `:message`, the error message; `:redact`, values replaced by
  `[redacted]` in Tempo's error text before the error is built and that
  text is cut to 256 bytes; and `:delivery`, which overrides the delivery
  inferred for a transport failure, such as `:not_sent` for a request that
  was stopped before it was sent.
  """
  @spec handle(term(), keyword()) :: {:ok, map() | list()} | {:error, Error.ProviderError.t()}
  def handle(response, opts \\ [])

  def handle({:ok, %{status: status} = response}, opts) when is_integer(status) do
    case decode(response) do
      {:ok, %{body: body}} when status in 200..299 and (is_map(body) or is_list(body)) ->
        {:ok, body}

      {:ok, %{body: body}} when status in 200..299 ->
        invalid_response(Keyword.get(opts, :message, "Tempo API response was not JSON"), body,
          status: status
        )

      {:error, %{body: body}} when status in 200..299 ->
        invalid_response(
          Keyword.get(opts, :message, "Tempo API response was not valid JSON"),
          body,
          status: status
        )

      # An error body that is not valid JSON stays raw: the error keeps the
      # status, Retry-After and the body size.
      {_decoded, response} ->
        http_error(response, opts)
    end
  end

  def handle(response, opts) do
    Transport.provider_error(
      response,
      [provider: :tempo, message: Keyword.get(opts, :message, @message)] ++
        Keyword.take(opts, [:delivery])
    )
  end

  @doc "Returns a provider error for a successful response whose payload is malformed."
  @spec invalid_response(String.t(), term(), keyword()) :: {:error, Error.ProviderError.t()}
  def invalid_response(message, body, opts \\ []) do
    {:error,
     Error.provider(message,
       provider: :tempo,
       reason: Keyword.get(opts, :reason, :invalid_response),
       status: Keyword.get(opts, :status),
       delivery: :response_received,
       details: Map.merge(%{body: body}, Keyword.get(opts, :details, %{}))
     )}
  end

  defp http_error(%{status: status, body: body} = response, opts) do
    error_opts = [
      provider: :tempo,
      message: Keyword.get(opts, :message, @message),
      reason: reason(status)
    ]

    error_opts =
      case error_message(body) do
        nil -> error_opts
        message -> Keyword.put(error_opts, :detail_message, redact(message, opts))
      end

    Transport.provider_error({:ok, response}, error_opts)
  end

  # Req leaves bodies undecoded (`decode_body: false`), since its decode error
  # would drop the status and the headers.
  defp decode(%{body: body} = response) when is_binary(body) and body != "" do
    if json?(response) do
      case Jason.decode(body) do
        {:ok, decoded} -> {:ok, %{response | body: decoded}}
        {:error, _error} -> {:error, response}
      end
    else
      {:ok, response}
    end
  end

  defp decode(response), do: {:ok, response}

  defp json?(%Req.Response{} = response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(fn value ->
      media_type = value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      media_type == "application/json" or String.ends_with?(media_type, "+json")
    end)
  end

  defp json?(_response), do: false

  defp reason(status) when status in 300..399, do: :redirect_not_followed
  defp reason(400), do: :bad_request
  defp reason(401), do: :unauthorized
  defp reason(403), do: :forbidden
  defp reason(404), do: :not_found
  defp reason(429), do: :rate_limited
  defp reason(status) when status in 500..599, do: :server_error
  defp reason(_status), do: :http_error

  defp error_message(%{"errors" => [_ | _] = errors}) do
    case for(%{"message" => message} when is_binary(message) <- errors, do: message) do
      [] -> nil
      messages -> Enum.join(messages, "; ")
    end
  end

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(_body), do: nil

  defp redact(message, opts) do
    opts
    |> Keyword.get(:redact, [])
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(message, &String.replace(&2, &1, "[redacted]"))
  end
end
