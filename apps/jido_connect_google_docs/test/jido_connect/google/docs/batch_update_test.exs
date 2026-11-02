defmodule Jido.Connect.Google.Docs.BatchUpdateTest do
  use ExUnit.Case, async: false

  alias Jido.Connect
  alias Jido.Connect.Google.Docs
  alias Jido.Connect.TestSupport.LiveSmoke

  @moduletag :capture_log

  # The recordings come from the write test in `live_smoke_test.exs`, which
  # sends the same batches to the empty scratch document.
  @document_id "1t47PcdwCWroHLmzucoB5YxoFZRyUD9a8dymU8ju-pwE"
  @write_scope "https://www.googleapis.com/auth/documents"
  @revision_before_insert "revision-read-before-the-insert"

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

  test "sends an insert batch with snake_case keys and returns Google's write acknowledgement" do
    recorded = LiveSmoke.fixture!(:google_docs, "batch_update_insert")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/documents/#{@document_id}:batchUpdate"

      assert wire_body(conn) == %{
               "requests" => [
                 %{
                   "insert_text" => %{
                     "location" => %{"index" => 1, "tab_id" => "t.0"},
                     "text" => "jcl-live-258-second\n"
                   }
                 },
                 %{
                   "insert_text" => %{
                     "location" => %{"index" => 1, "tab_id" => "t.0"},
                     "text" => "jcl-live-258-first\n"
                   }
                 }
               ],
               "writeControl" => %{"required_revision_id" => @revision_before_insert}
             }

      Req.Test.json(conn, recorded)
    end)

    assert {:ok, result} =
             batch_update(%{
               document_id: @document_id,
               requests: [
                 %{
                   "insert_text" => %{
                     "location" => %{"index" => 1, "tab_id" => "t.0"},
                     "text" => "jcl-live-258-second\n"
                   }
                 },
                 %{
                   "insert_text" => %{
                     "location" => %{"index" => 1, "tab_id" => "t.0"},
                     "text" => "jcl-live-258-first\n"
                   }
                 }
               ],
               write_control: %{"required_revision_id" => @revision_before_insert}
             })

    # Google answers an insert with an empty reply object and sends no document.
    assert result == %{
             document_id: @document_id,
             replies: [%{}, %{}],
             write_control: %{
               "requiredRevisionId" => recorded["writeControl"]["requiredRevisionId"]
             }
           }
  end

  test "the action metadata lists the write acknowledgement fields" do
    action =
      Enum.find(Docs.integration().actions, &(&1.id == "google.docs.document.batch_update"))

    assert Enum.map(action.output, &{&1.name, &1.type}) == [
             {:document_id, :string},
             {:write_control, :map},
             {:replies, {:array, :map}},
             {:document, :map}
           ]

    assert action.risk == :destructive
    assert action.confirmation == :always
    assert action.scopes == [@write_scope]
  end

  defp wire_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  defp batch_update(input) do
    connection =
      Connect.Connection.new!(%{
        id: "conn_1",
        provider: :google_docs,
        profile: :user,
        tenant_id: "tenant_1",
        owner_type: :app_user,
        owner_id: "user_1",
        status: :connected,
        scopes: [@write_scope]
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
        scopes: [@write_scope]
      })

    Connect.invoke(Docs.integration(), "google.docs.document.batch_update", input,
      context: context,
      credential_lease: lease
    )
  end
end
