defmodule Jido.Connect.GitHub.CatalogPacks do
  @moduledoc """
  Reviewed catalog packs for common GitHub tool surfaces.

  `issues_read/0` and `issues_manage/0` use explicit Action lists. `read_only/0`
  and `full/0` use filters, so a later package release can add matching Actions
  to those packs.
  """

  alias Jido.Connect.Catalog.Pack

  @doc "Returns all built-in GitHub catalog packs."
  @spec all() :: [Pack.t()]
  def all, do: [read_only(), issues_read(), issues_manage(), full()]

  @doc "Returns an expanding pack of all read-only GitHub Actions."
  @spec read_only() :: Pack.t()
  def read_only do
    Pack.new!(%{
      id: "github.read_only.v1",
      label: "GitHub read-only tools",
      description: "Read GitHub repositories, issues, pull requests, workflows, and releases.",
      filters: %{type: :action, risk: :read},
      metadata: %{package: :jido_connect_github, risk: :read, selection: :expanding}
    })
  end

  @doc "Returns an explicit pack of GitHub issue-reading Actions."
  @spec issues_read() :: Pack.t()
  def issues_read do
    Pack.new!(%{
      id: "github.issues_read.v1",
      label: "GitHub issue reader",
      description: "Search and read GitHub issues and issue comments.",
      allowed_tools: [
        "github.issue.list",
        "github.issue.search",
        "github.issue_comment.list"
      ],
      metadata: %{package: :jido_connect_github, risk: :read, selection: :explicit}
    })
  end

  @doc "Returns an explicit pack of GitHub issue-reading and issue-writing Actions."
  @spec issues_manage() :: Pack.t()
  def issues_manage do
    Pack.new!(%{
      id: "github.issues_manage.v1",
      label: "GitHub issue manager",
      description: "Read and manage GitHub issues, labels, assignments, and comments.",
      allowed_tools: [
        "github.issue.list",
        "github.issue.search",
        "github.issue.create",
        "github.issue.update",
        "github.issue.assign",
        "github.issue.label.add",
        "github.issue.label.remove",
        "github.issue_comment.list",
        "github.issue_comment.create"
      ],
      metadata: %{package: :jido_connect_github, risk: :write, selection: :explicit}
    })
  end

  @doc "Returns an expanding pack of all GitHub Actions. Use it only in trusted hosts."
  @spec full() :: Pack.t()
  def full do
    Pack.new!(%{
      id: "github.full.v1",
      label: "All GitHub tools",
      description: "All GitHub Actions installed with this provider package.",
      filters: %{type: :action},
      metadata: %{package: :jido_connect_github, risk: :mixed, selection: :expanding}
    })
  end
end
