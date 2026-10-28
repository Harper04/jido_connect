defmodule Jido.Connect.Airtable.CatalogPacks do
  @moduledoc """
  Curated catalog packs for common Airtable tool surfaces.

  Packs are storage-free catalog filters that hosts pass to the catalog
  boundary to scope tool discovery and invocation.

  ## Packs

  | Pack | Risk | Tools |
  |------|------|-------|
  | `:airtable_reader` | read | base schema and record queries |
  | `:airtable_editor` | write | reader + record create and update |
  | `:airtable_destructive` | destructive | editor + record delete |

  Triggers are subscribed to independently and are not listed in packs.
  """

  alias Jido.Connect.Catalog.Pack

  @base_read_tools [
    "airtable.bases.list",
    "airtable.bases.get",
    "airtable.tables.list"
  ]

  @record_read_tools [
    "airtable.records.list",
    "airtable.records.get"
  ]

  @reader_tools @base_read_tools ++
                  @record_read_tools

  @record_write_tools [
    "airtable.records.create",
    "airtable.records.update",
    "airtable.records.batch_create",
    "airtable.records.batch_update"
  ]

  @record_delete_tools [
    "airtable.records.delete",
    "airtable.records.batch_delete"
  ]

  @editor_tools @reader_tools ++
                  @record_write_tools

  @destructive_tools @editor_tools ++
                       @record_delete_tools

  @doc "Returns all built-in Airtable catalog packs."
  def all, do: [reader(), editor(), destructive()]

  @doc "Read-only Airtable pack for base schema and record queries."
  def reader do
    Pack.new!(%{
      id: :airtable_reader,
      label: "Airtable reader",
      description: "Read Airtable base schemas and records without mutation tools.",
      filters: %{provider: :airtable},
      allowed_tools: @reader_tools,
      metadata: %{package: :jido_connect_airtable, risk: :read}
    })
  end

  @doc "Airtable editor pack for read, record create, and update."
  def editor do
    Pack.new!(%{
      id: :airtable_editor,
      label: "Airtable editor",
      description: "Read Airtable base schemas and records, plus create and update records.",
      filters: %{provider: :airtable},
      allowed_tools: @editor_tools,
      metadata: %{package: :jido_connect_airtable, risk: :write}
    })
  end

  @doc "Airtable destructive pack for record deletion."
  def destructive do
    Pack.new!(%{
      id: :airtable_destructive,
      label: "Airtable destructive",
      description: "Read, create, update, and delete Airtable records.",
      filters: %{provider: :airtable},
      allowed_tools: @destructive_tools,
      metadata: %{package: :jido_connect_airtable, risk: :destructive}
    })
  end
end
