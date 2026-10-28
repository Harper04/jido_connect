defmodule Jido.Connect.Google.Contacts.CatalogPacks do
  @moduledoc "Curated catalog packs for common Google Contacts tool surfaces."

  alias Jido.Connect.Catalog.Pack

  @readonly_tools [
    "google.contacts.person.list",
    "google.contacts.person.get",
    "google.contacts.person.search",
    "google.contacts.group.list",
    "google.contacts.person.batch_get",
    "google.contacts.directory.list",
    "google.contacts.directory.search",
    "google.contacts.other.list",
    "google.contacts.other.search",
    "google.contacts.group.get",
    "google.contacts.group.batch_get"
  ]

  @manager_tools @readonly_tools ++
                   [
                     "google.contacts.person.batch_create",
                     "google.contacts.person.batch_update",
                     "google.contacts.person.create",
                     "google.contacts.person.update",
                     "google.contacts.other.copy",
                     "google.contacts.group.create",
                     "google.contacts.group.update",
                     "google.contacts.group.member.modify"
                   ]

  @destructive_tools @manager_tools ++
                       [
                         "google.contacts.person.batch_delete",
                         "google.contacts.person.delete",
                         "google.contacts.group.delete"
                       ]

  @doc "Returns all built-in Google Contacts catalog packs."
  def all, do: [readonly(), manager(), destructive()]

  @doc "Read-only Contacts pack for person and contact group reads."
  def readonly do
    Pack.new!(%{
      id: :google_contacts_readonly,
      label: "Google Contacts read-only",
      description: "Read Google Contacts people and contact groups without mutation tools.",
      filters: %{provider: :google_contacts},
      allowed_tools: @readonly_tools,
      metadata: %{package: :jido_connect_google_contacts, risk: :read}
    })
  end

  @doc "Contacts manager pack with read and non-destructive person and group tools."
  def manager do
    Pack.new!(%{
      id: :google_contacts_manager,
      label: "Google Contacts manager",
      description: "Read, create, and update Google Contacts people and contact groups.",
      filters: %{provider: :google_contacts},
      allowed_tools: @manager_tools,
      metadata: %{package: :jido_connect_google_contacts, risk: :write}
    })
  end

  @doc "Contacts destructive pack with person and group deletion tools."
  def destructive do
    Pack.new!(%{
      id: :google_contacts_destructive,
      label: "Google Contacts destructive",
      description: "Read, manage, and delete Google Contacts people and contact groups.",
      filters: %{provider: :google_contacts},
      allowed_tools: @destructive_tools,
      metadata: %{package: :jido_connect_google_contacts, risk: :destructive}
    })
  end
end
