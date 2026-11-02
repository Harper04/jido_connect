defmodule Jido.Connect.Tempo.Client.Pagination do
  @moduledoc """
  Offset and limit traversal of Tempo's pageable GET responses.

  A pageable response carries `results` and `metadata` with `offset`,
  `limit`, `count` and, unless it is the last page, a `next` link.
  `collect/3` reads every page and returns all results, or fails the whole
  read.

  The next page is rebuilt from the validated metadata: the same path and
  query parameters at the connection's origin, with `offset` advanced by the
  page's `count`. The `next` link is only checked, never requested. It must
  pass `Jido.Connect.Tempo.Client.Request.tempo_link?/2` for the requested
  path: Tempo's links name `https://api.tempo.io` even on a regional origin,
  so a link on another Tempo origin is accepted while the request stays at
  the connection's origin. Any other origin or path is a `:foreign_next_link`
  error without a request.

  Bounds, each a positive integer option with a default from `defaults/0`:

  - `:limit` (50): page size sent to Tempo.
  - `:max_pages` (20): requests per read. A read that needs more fails with
    `:page_limit_exceeded` before the next request.
  - `:max_results` (1000): results per read. More results fail with
    `:result_limit_exceeded`; a read with exactly this many succeeds.

  Other failures that end the whole read: a page whose offset was already
  read, or an empty page that announces a next one (`:repeated_offset`), a
  page without valid `results` or `metadata`, or a `next` link whose `offset`
  is not the page's `offset` plus `count` (`:invalid_pagination`), and any
  failed request. The last check stops a short page that announces a full
  one, which would otherwise read results twice. Byte limits on the collected
  results are host policy.
  """

  alias Jido.Connect.Error
  alias Jido.Connect.Tempo.Client.{Request, Response, Transport}

  @defaults [limit: 50, max_pages: 20, max_results: 1_000]

  @doc "Returns the default bounds."
  @spec defaults() :: keyword(pos_integer())
  def defaults, do: @defaults

  @doc """
  Reads every page of a pageable GET for `path` and returns all results.

  Options: `:params` (query parameters other than `offset` and `limit`) and
  the bounds `:limit`, `:max_pages` and `:max_results`.
  """
  @spec collect(Request.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.ProviderError.t()}
  def collect(%Request{} = request, path, opts \\ []) when is_binary(path) do
    bounds = Map.new(@defaults, fn {key, default} -> {key, bound!(opts, key, default)} end)
    params = opts |> Keyword.get(:params, []) |> Keyword.drop([:offset, :limit])

    state = %{offset: 0, pages: 0, total: 0, seen: MapSet.new(), chunks: []}
    read(request, path, params, bounds, state)
  end

  defp read(request, path, params, bounds, state) do
    page_params = params ++ [offset: state.offset, limit: bounds.limit]

    with {:ok, body} <- Transport.get(request, path, params: page_params),
         {:ok, page} <- page(body, state) do
      state = %{
        state
        | pages: state.pages + 1,
          total: state.total + page.count,
          seen: MapSet.put(state.seen, state.offset),
          chunks: [page.results | state.chunks]
      }

      cond do
        state.total > bounds.max_results ->
          error(:result_limit_exceeded, "Tempo read exceeds the result limit", %{
            max_results: bounds.max_results
          })

        is_nil(page.next) ->
          {:ok, state.chunks |> Enum.reverse() |> Enum.concat()}

        true ->
          next(request, path, params, bounds, state, page)
      end
    end
  end

  defp next(request, path, params, bounds, state, page) do
    next_offset = state.offset + page.count

    cond do
      not Request.tempo_link?(page.next, path) ->
        error(:foreign_next_link, "Tempo next link leaves the Tempo origins or the path", %{})

      MapSet.member?(state.seen, next_offset) ->
        error(:repeated_offset, "Tempo pagination repeated an offset", %{offset: next_offset})

      link_offset(page.next) != Integer.to_string(next_offset) ->
        invalid_page()

      state.pages >= bounds.max_pages ->
        error(:page_limit_exceeded, "Tempo read exceeds the page limit", %{
          max_pages: bounds.max_pages
        })

      true ->
        read(request, path, params, bounds, %{state | offset: next_offset})
    end
  end

  defp page(%{"results" => results, "metadata" => %{} = metadata}, state)
       when is_list(results) do
    offset = metadata["offset"]
    count = metadata["count"]
    next = metadata["next"]

    cond do
      MapSet.member?(state.seen, offset) ->
        error(:repeated_offset, "Tempo pagination repeated an offset", %{offset: offset})

      offset != state.offset or count != length(results) or not (is_nil(next) or is_binary(next)) ->
        invalid_page()

      true ->
        {:ok, %{results: results, count: count, next: next}}
    end
  end

  defp page(_body, _state), do: invalid_page()

  defp invalid_page, do: error(:invalid_pagination, "Tempo page metadata was invalid", %{})

  defp link_offset(link) do
    URI.decode_query(URI.parse(link).query || "")["offset"]
  end

  defp error(reason, message, details) do
    Response.invalid_response(message, nil, reason: reason, details: details)
  end

  defp bound!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end
end
