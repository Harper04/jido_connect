defmodule Jido.Connect.Google.Docs.DocumentTabsTest do
  use ExUnit.Case, async: false

  alias Jido.Connect
  alias Jido.Connect.Google.Docs
  alias Jido.Connect.TestSupport.LiveSmoke

  # The recordings read the prepared document with the top-level tabs First
  # and Second and the child tab Nested under Second.
  @document_id "1Ej83l690dmUeDhX90Suxdef_SR97A-Kleilmdg5G9_E"
  @readonly_scope "https://www.googleapis.com/auth/documents.readonly"

  setup {Req.Test, :verify_on_exit!}

  setup do
    Application.put_env(
      :jido_connect_google_docs,
      :google_docs_api_base_url,
      "https://docs.test"
    )

    Application.put_env(:jido_connect_google, :google_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:jido_connect_google_docs, :google_docs_api_base_url)
      Application.delete_env(:jido_connect_google, :google_req_options)
    end)
  end

  test "returns both top-level tabs and the nested child tab with their bodies" do
    recorded = LiveSmoke.fixture!(:google_docs, "document_with_tabs_content")
    %{"tabs" => [first, %{"childTabs" => [nested]} = second]} = recorded

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/documents/#{@document_id}"
      assert conn.query_params["includeTabsContent"] == "true"
      Req.Test.json(conn, recorded)
    end)

    assert {:ok, %{document: document}} =
             get_document(%{document_id: @document_id, include_tabs_content: true})

    assert [
             %{tab_id: "t.0", title: "First", body: first_body, child_tabs: []},
             %{
               tab_id: "t.1mzp8ctna0b6",
               title: "Second",
               body: second_body,
               child_tabs: [
                 %{tab_id: "t.xii08ty2ttum", title: "Nested", body: nested_body, child_tabs: []}
               ]
             }
           ] = document.tabs

    assert first_body == first["documentTab"]["body"]
    assert second_body == second["documentTab"]["body"]
    assert nested_body == nested["documentTab"]["body"]

    assert indexes(first_body) == [{nil, 1}, {1, 22}, {22, 23}]
    assert indexes(second_body) == [{nil, 1}, {1, 23}, {23, 24}]
    assert indexes(nested_body) == [{nil, 1}, {1, 23}, {23, 24}]
  end

  test "a legacy response without tabs keeps the first tab's content in the document body" do
    recorded = LiveSmoke.fixture!(:google_docs, "document_without_tabs_content")
    refute Map.has_key?(recorded, "tabs")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.query_params["includeTabsContent"] == "false"
      Req.Test.json(conn, recorded)
    end)

    assert {:ok, %{document: document}} =
             get_document(%{document_id: @document_id, include_tabs_content: false})

    assert document.tabs == []
    assert document.body == recorded["body"]
    assert indexes(document.body) == [{nil, 1}, {1, 22}, {22, 23}]
  end

  defp indexes(%{"content" => content}),
    do: Enum.map(content, &{&1["startIndex"], &1["endIndex"]})

  defp get_document(input) do
    connection =
      Connect.Connection.new!(%{
        id: "conn_1",
        provider: :google_docs,
        profile: :user,
        tenant_id: "tenant_1",
        owner_type: :app_user,
        owner_id: "user_1",
        status: :connected,
        scopes: [@readonly_scope]
      })

    context =
      Connect.Context.new!(%{
        tenant_id: "tenant_1",
        actor: %{id: "user_1", type: :user},
        connection: connection
      })

    lease =
      Connect.CredentialLease.new!(%{
        connection_id: "conn_1",
        provider: :google_docs,
        profile: :user,
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
        fields: %{access_token: "token"},
        scopes: [@readonly_scope]
      })

    Connect.invoke(Docs.integration(), "google.docs.document.get", input,
      context: context,
      credential_lease: lease
    )
  end
end
