defmodule Jido.Connect.Atlassian.ADF do
  @moduledoc """
  Atlassian Document Format (ADF) conversion shared by the Jira and Confluence
  packages.

  `to_text/1` is the strict rendering of the former
  `Jido.Connect.Confluence.ADF`. It fails the whole document on any node or
  text mark outside its supported subset and on links that are not HTTPS.

  `from_markdown/2` converts bounded Markdown into a fixed ADF v1 subset for
  paragraphs, headings, lists, block quotes, fenced code, hard line breaks,
  horizontal rules and HTTPS links.
  """

  alias Jido.Connect.Atlassian.ADF.{Markdown, StrictText}

  @default_max_markdown_length 100_000

  @doc """
  Renders an ADF v1 document as text with the strict rendering.

  Returns `:error` for a document outside the supported subset.
  """
  @spec to_text(term()) :: {:ok, String.t()} | :error
  defdelegate to_text(document), to: StrictText

  @doc """
  Converts bounded Markdown into an ADF v1 document.

  Option `:max_length` bounds the input in characters; the default is
  #{@default_max_markdown_length}. Longer input and non-strings return `:error`.
  """
  @spec from_markdown(term(), keyword()) :: {:ok, map()} | :error
  def from_markdown(markdown, opts \\ []) do
    Markdown.from_markdown(
      markdown,
      Keyword.get(opts, :max_length, @default_max_markdown_length)
    )
  end
end
