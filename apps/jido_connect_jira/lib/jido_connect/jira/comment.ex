defmodule Jido.Connect.Jira.Comment do
  @moduledoc """
  Normalized Jira issue comment.

  `url` is the comment's REST API URL, Jira's `self`. `body` is the plain text
  of the comment body, rendered as `Jido.Connect.Jira.ADFText` describes, and
  `body_unsupported_nodes` lists the ADF node and mark types skipped while
  rendering it. `body_adf` is the original ADF document, unchanged.
  `visibility` is Jira's visibility restriction as returned, such as
  `%{"type" => "role", "value" => "Developers", "identifier" => "Developers"}`;
  it is absent for a comment that every issue reader can see.

  A comment without a body has none of the three body fields. An empty ADF
  document keeps `body: ""` next to its `body_adf`.
  """

  alias Jido.Connect.Jira.User

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              url: Zoi.string() |> Zoi.nullish() |> Zoi.optional(),
              body: Zoi.string() |> Zoi.nullish() |> Zoi.optional(),
              body_adf: Zoi.map() |> Zoi.nullish() |> Zoi.optional(),
              body_unsupported_nodes: Zoi.list(Zoi.string()) |> Zoi.nullish() |> Zoi.optional(),
              rendered_body: Zoi.string() |> Zoi.nullish() |> Zoi.optional(),
              author: User.schema() |> Zoi.nullish() |> Zoi.optional(),
              update_author: User.schema() |> Zoi.nullish() |> Zoi.optional(),
              created_at: Zoi.string() |> Zoi.nullish() |> Zoi.optional(),
              updated_at: Zoi.string() |> Zoi.nullish() |> Zoi.optional(),
              visibility: Zoi.map() |> Zoi.nullish() |> Zoi.optional(),
              jsd_public: Zoi.boolean() |> Zoi.nullish() |> Zoi.optional(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
  def new!(attrs), do: Zoi.parse!(@schema, attrs)
  def new(attrs), do: Zoi.parse(@schema, attrs)
end
