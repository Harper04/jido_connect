defmodule Jido.Connect.GitHub.CatalogPacksTest do
  use ExUnit.Case, async: true

  alias Jido.Connect
  alias Jido.Connect.AI.CatalogToolSource
  alias Jido.Connect.Catalog
  alias Jido.Connect.GitHub
  alias Jido.Connect.GitHub.CatalogPacks

  defmodule FakeGitHubClient do
    def list_issues("agentjido/jido", "open", "token") do
      {:ok,
       [
         %{
           number: 42,
           url: "https://github.test/agentjido/jido/issues/42",
           title: "Test issue",
           state: "open"
         }
       ]}
    end
  end

  test "all returns packs in ascending privilege order" do
    assert Enum.map(CatalogPacks.all(), & &1.id) == [
             "github.read_only.v1",
             "github.issues_read.v1",
             "github.issues_manage.v1",
             "github.full.v1"
           ]
  end

  test "issue packs select explicit GitHub Actions" do
    assert {:ok, read_items} = Catalog.reviewed_items(GitHub, CatalogPacks.issues_read())

    assert MapSet.new(read_items, & &1.id) ==
             MapSet.new([
               "github.issue.list",
               "github.issue.search",
               "github.issue_comment.list"
             ])

    assert {:ok, manage_items} = Catalog.reviewed_items(GitHub, CatalogPacks.issues_manage())

    assert MapSet.subset?(
             MapSet.new(read_items, & &1.id),
             MapSet.new(manage_items, & &1.id)
           )

    assert Enum.any?(manage_items, &(&1.id == "github.issue.create"))
  end

  test "full pack projects every generated GitHub Action" do
    assert {:ok, items} = Catalog.reviewed_items(GitHub, CatalogPacks.full())

    assert Enum.map(items, & &1.module) == GitHub.Plugin.actions()
  end

  test "read-only pack projects only read Actions" do
    assert {:ok, items} = Catalog.reviewed_items(GitHub, CatalogPacks.read_only())

    assert items != []
    assert Enum.all?(items, &(&1.type == :action and &1.risk == :read))
  end

  test "Jido AI loads and executes a GitHub Action from a reviewed pack" do
    assert {:ok, source} = CatalogToolSource.new(GitHub, CatalogPacks.issues_read())

    assert {:ok, tools} =
             Jido.AI.ToolSource.load(%{jido_ai_tool_sources: [source]})

    assert Enum.map(tools, & &1.name) == [
             "github_issue_list",
             "github_issue_search",
             "github_issue_comment_list"
           ]

    tool = Enum.find(tools, &(&1.name == "github_issue_list"))
    {context, lease} = context_and_lease()

    call = %{
      id: "call-1",
      name: tool.name,
      arguments: %{"repo" => "agentjido/jido", "state" => "open"}
    }

    assert {:ok,
            %{
              issues: [
                %{
                  number: 42,
                  title: "Test issue",
                  state: "open"
                }
              ]
            }} =
             Jido.AI.ToolSource.run(
               Jido.AI.ToolSource.executor(tool),
               call,
               %{integration_context: context, credential_lease: lease}
             )
  end

  test "Jido AI rejects mutation packs until prepare and commit authorization is integrated" do
    assert {:error, %Connect.Error.ValidationError{reason: :catalog_mutation_tool_not_enabled}} =
             CatalogToolSource.new(GitHub, CatalogPacks.issues_manage())
  end

  defp context_and_lease do
    connection =
      Connect.Connection.new!(%{
        id: "conn-1",
        provider: :github,
        profile: :user,
        tenant_id: "tenant-1",
        owner_type: :user,
        owner_id: "user-1",
        status: :connected,
        scopes: ["repo"]
      })

    context =
      Connect.Context.new!(%{
        tenant_id: "tenant-1",
        actor: %{id: "user-1", type: :user},
        connection: connection
      })

    lease =
      Connect.CredentialLease.from_connection!(
        connection,
        %{access_token: "token", github_client: FakeGitHubClient},
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      )

    {context, lease}
  end
end
