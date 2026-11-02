defmodule Jido.Connect.Jira.Client.Normalizer.IssueFields do
  @moduledoc false

  # Finds the requested Jira field keys that an issue payload does not carry.
  # Jira returns `null` for a known field without a value and leaves out a
  # requested field it does not return, such as `parent` on a top-level issue
  # or a key that does not exist on the site.

  alias Jido.Connect.Data

  # The `fields` keys that `Normalizer.issue/2` reads; `*all` stands for them.
  @read_keys ~w(summary description status issuetype project assignee reporter priority
                labels components fixVersions duedate resolution timetracking created updated)

  # Top-level issue properties that callers sometimes list as fields.
  @top_level_keys ~w(id key self expand)

  @doc """
  Returns the requested keys that `fields` does not contain, in request order.

  `requested` is the `fields` list of the request, or `nil` when nothing was
  requested. Entries can hold comma-separated keys. `*all` stands for the keys
  the normalizer reads, other `*` selectors are skipped, and `-key` removes a
  key.
  """
  @spec missing(term(), [String.t()] | nil) :: [String.t()]
  def missing(_fields, nil), do: []

  def missing(fields, requested) when is_list(requested) do
    fields = if is_map(fields), do: fields, else: %{}

    requested
    |> keys()
    |> Enum.filter(&(Data.get(fields, &1, :missing) == :missing))
  end

  defp keys(requested) do
    {excluded, included} =
      requested
      |> Enum.flat_map(&String.split(to_string(&1), ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.split_with(&String.starts_with?(&1, "-"))

    excluded = Enum.map(excluded, &String.trim_leading(&1, "-"))

    included
    |> Enum.flat_map(&expand/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in excluded or &1 in @top_level_keys))
  end

  defp expand("*all"), do: @read_keys
  defp expand("*" <> _selector), do: []
  defp expand(key), do: [key]
end
