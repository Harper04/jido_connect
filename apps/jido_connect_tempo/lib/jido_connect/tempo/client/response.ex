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
  """

  alias Jido.Connect.Error
  alias Jido.Connect.Provider.Transport

  @message "Tempo API request failed"

  @doc "Returns the decoded JSON body of a successful response or a normalized error."
  @spec handle(term(), keyword()) :: {:ok, map() | list()} | {:error, Error.ProviderError.t()}
  def handle(response, opts \\ [])

  def handle({:ok, %{status: status, body: body}}, _opts)
      when status in 200..299 and (is_map(body) or is_list(body)) do
    {:ok, body}
  end

  def handle({:ok, %{status: status, body: body}}, opts) when status in 200..299 do
    invalid_response(Keyword.get(opts, :message, "Tempo API response was not JSON"), body,
      status: status
    )
  end

  def handle({:ok, %{status: status, body: body}} = response, opts) when is_integer(status) do
    error_opts = [
      provider: :tempo,
      message: Keyword.get(opts, :message, @message),
      reason: reason(status)
    ]

    error_opts =
      case error_message(body) do
        nil -> error_opts
        message -> Keyword.put(error_opts, :detail_message, message)
      end

    Transport.provider_error(response, error_opts)
  end

  # Req's JSON decoding failed; the exception's `data` holds the raw body, so
  # neither it nor the exception is kept.
  def handle({:error, %Jason.DecodeError{}}, opts) do
    invalid_response(Keyword.get(opts, :message, "Tempo API response was not valid JSON"), nil)
  end

  def handle(response, opts) do
    Transport.provider_error(response,
      provider: :tempo,
      message: Keyword.get(opts, :message, @message)
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
end
