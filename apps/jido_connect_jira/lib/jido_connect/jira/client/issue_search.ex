defmodule Jido.Connect.Jira.Client.IssueSearch do
  @moduledoc """
  Jira enhanced JQL search, `POST /rest/api/3/search/jql`.

  Atlassian removed the earlier `POST /rest/api/3/search`, which now answers
  `410 Gone`. Enhanced search links its pages with an opaque `nextPageToken`,
  marks the last page with `isLast` and returns no `total`, `startAt` or
  `maxResults`. `search/3` requests one page and returns:

    * `issues`: the normalized issues of the page. A page can be empty while
      `is_last` is `false`; continue with its token.
    * `next_page_token`: the token for the next page, `nil` on the last page.
    * `is_last`: Jira's `isLast`.
    * `max_results`: the page size sent with the request. Jira can return
      fewer issues.

  `start_at` is deprecated for one release: `0` and `nil` are accepted and
  ignored, any other value fails with a `Jido.Connect.Error.ValidationError`
  before a request is sent. Page with `:next_page_token` instead.
  """

  alias Jido.Connect.Error
  alias Jido.Connect.Jira.Client.{Request, Response, Transport}

  @default_fields ~w(summary status assignee updated description project duedate)

  @doc "Returns the fields requested when the caller names none."
  @spec default_fields() :: [String.t()]
  def default_fields, do: @default_fields

  @doc """
  Requests one page of issues for `jql`.

  Options are `:max_results` (default 50), `:next_page_token`, `:fields`
  (default `default_fields/0`, also used for an empty list, because Jira
  returns only issue IDs without fields) and the deprecated `:start_at`.
  """
  @spec search(String.t(), Request.t(), keyword()) :: {:ok, map()} | {:error, Error.error()}
  def search(jql, %Request{} = request, opts \\ []) when is_binary(jql) and is_list(opts) do
    with :ok <- check_start_at(Keyword.get(opts, :start_at)) do
      fields = fields(Keyword.get(opts, :fields))
      max_results = Keyword.get(opts, :max_results, 50)

      body =
        %{jql: jql, maxResults: max_results, fields: fields}
        |> put_token(Keyword.get(opts, :next_page_token))

      request
      |> Transport.request()
      |> Req.post(url: Request.url(request, "/rest/api/3/search/jql"), json: body)
      |> Response.handle_issue_search_response(fields)
      |> case do
        {:ok, page} -> {:ok, Map.put(page, :max_results, max_results)}
        {:error, _error} = error -> error
      end
    end
  end

  defp check_start_at(start_at) when start_at in [nil, 0], do: :ok

  defp check_start_at(start_at) do
    {:error,
     Error.validation(
       "Jira issue search no longer supports start_at; page with next_page_token",
       reason: :deprecated_start_at,
       subject: :start_at,
       details: %{start_at: start_at, accepted: [0]}
     )}
  end

  defp fields(fields) when fields in [nil, []], do: @default_fields
  defp fields(fields) when is_list(fields), do: fields

  defp put_token(body, token) when is_binary(token) and token != "",
    do: Map.put(body, :nextPageToken, token)

  defp put_token(body, _token), do: body
end
