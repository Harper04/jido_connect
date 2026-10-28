defmodule Jido.Connect.AI.CatalogToolSourceTest do
  use ExUnit.Case, async: true

  alias Jido.Connect
  alias Jido.Connect.AI.CatalogToolSource
  alias Jido.Connect.Catalog.Pack

  defmodule Handler do
    def run(input, _context), do: {:ok, input}
  end

  defmodule Integration do
    use Jido.Connect

    integration do
      id :ai_catalog_fixture
      name "AI Catalog Fixture"
      category :test
    end

    catalog do
      package :jido_connect
      metadata %{version: "1.0.0"}
    end

    auth do
      api_key :user do
        default? true
        owner :app_user
        subject :user
        label "API key"
        credential_fields [:api_key]
        lease_fields [:api_key]
        scopes ["read"]
        default_scopes ["read"]
      end
    end

    actions do
      action :get_item do
        id "fixture.item.get"
        resource :item
        verb :get
        data_classification :workspace_metadata
        label "Get item"
        description "Get one item."
        handler Handler
        effect :read

        access do
          auth :user
          scopes ["read"]
        end

        input do
          field :id, :string, required?: true
        end

        output do
          field :id, :string, required?: true
        end
      end

      action :update_item do
        id "fixture.item.update"
        resource :item
        verb :update
        data_classification :workspace_metadata
        label "Update item"
        description "Update one item."
        handler Handler
        effect :external_write, confirmation: :required_for_ai

        access do
          auth :user
          scopes ["read"]
        end

        input do
          field :id, :string, required?: true
        end

        output do
          field :id, :string, required?: true
        end
      end
    end
  end

  test "loads reviewed catalog Actions as portable Jido AI tools" do
    assert {:ok, source} = CatalogToolSource.new(Integration, pack())

    assert {:ok, [tool]} =
             Jido.AI.ToolSource.load(%{jido_ai_tool_sources: [source]})

    assert tool.name == "fixture_item_get"
    assert tool.description == "Get one item."
    assert tool.strict
    assert tool.parameter_schema["required"] == ["id"]
    assert tool.source.module == CatalogToolSource
  end

  test "executes the reviewed generated Action with current Connect context" do
    assert {:ok, source} = CatalogToolSource.new(Integration, pack())

    assert {:ok, [tool]} =
             Jido.AI.ToolSource.load(%{jido_ai_tool_sources: [source]})

    {context, lease} = context_and_lease()

    call = %{
      id: "call-1",
      name: tool.name,
      arguments: %{"id" => "item-1"}
    }

    assert {:ok, %{id: "item-1"}} =
             Jido.AI.ToolSource.run(
               Jido.AI.ToolSource.executor(tool),
               call,
               %{integration_context: context, credential_lease: lease}
             )
  end

  test "rejects a tool when its reviewed fingerprint changed" do
    assert {:ok, {CatalogToolSource, config}} = CatalogToolSource.new(Integration, pack())

    changed_tools =
      Enum.map(config.tools, &Map.put(&1, :reviewed_fingerprint, "changed-fingerprint"))

    changed_source = {CatalogToolSource, %{config | tools: changed_tools}}

    assert {:ok, [tool]} =
             Jido.AI.ToolSource.load(%{jido_ai_tool_sources: [changed_source]})

    {context, lease} = context_and_lease()

    assert {:error, %Connect.Error.ValidationError{reason: :reviewed_tool_changed}} =
             Jido.AI.ToolSource.run(
               Jido.AI.ToolSource.executor(tool),
               %{id: "call-1", name: tool.name, arguments: %{"id" => "item-1"}},
               %{integration_context: context, credential_lease: lease}
             )
  end

  test "rejects mutation tools until prepare and commit authorization is integrated" do
    mutation_pack =
      Pack.new!(%{
        id: :fixture_writer,
        allowed_tools: ["fixture.item.update"]
      })

    assert {:error,
            %Connect.Error.ValidationError{
              reason: :catalog_mutation_tool_not_enabled,
              subject: "ai_catalog_fixture:action:fixture.item.update"
            }} = CatalogToolSource.new(Integration, mutation_pack)
  end

  defp pack do
    Pack.new!(%{
      id: :fixture_reader,
      allowed_tools: ["fixture.item.get"]
    })
  end

  defp context_and_lease do
    connection =
      Connect.Connection.new!(%{
        id: "conn-1",
        provider: :ai_catalog_fixture,
        profile: :user,
        tenant_id: "tenant-1",
        owner_type: :app_user,
        owner_id: "user-1",
        status: :connected,
        scopes: ["read"]
      })

    context =
      Connect.Context.new!(%{
        tenant_id: "tenant-1",
        actor: %{id: "user-1", type: :app_user},
        connection: connection
      })

    lease =
      Connect.CredentialLease.from_connection!(connection, %{api_key: "secret"},
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      )

    {context, lease}
  end
end
