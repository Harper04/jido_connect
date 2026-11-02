defmodule Jido.Connect.Google.Drive.ChangeFeedTest do
  use ExUnit.Case, async: false

  alias Jido.Connect
  alias Jido.Connect.Google.Drive
  alias Jido.Connect.TestSupport.LiveSmoke

  # The prepared watch folder and the objects the live tests created and
  # removed again while they recorded the fixtures.
  @watch_folder "1WBlaIDsYb-vmynE8OnECx6l7vunVL0So"
  @added "16G0zkY3iWCmTdJGqvj3OyCTAPqU0fgU9"
  @subfolder "1ZZhnM_eWX4wvZnoTS-LG1q5JiuG_6Wx1"
  @nested "1A36l7QZp2EifPB3FQAMdg1r9SjUYbw3o"
  @trashed "1wuBTBgKsmgGOL06HHHWxvFQgS16PuL-k"
  @removed "169L8tikOCrVn8N3aHI4ZPRnn0xY0Rr9C"
  @shared_drive "0ANlr4uaAlMbAUk9PVA"

  # Drive's page tokens are opaque; the host passes its stored one back.
  @checkpoint "stored-checkpoint"

  # The projection of the folder lookup the recordings were made with. Drive
  # returns only the requested fields, and a file without `name` does not
  # normalize.
  @folder_lookup_fields "id,name,mimeType,driveId"

  setup {Req.Test, :verify_on_exit!}

  setup do
    Application.put_env(
      :jido_connect_google_drive,
      :google_drive_api_base_url,
      "https://drive.test"
    )

    Application.put_env(:jido_connect_google, :google_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:jido_connect_google_drive, :google_drive_api_base_url)
      Application.delete_env(:jido_connect_google, :google_req_options)
    end)
  end

  describe "google.drive.collection.changes" do
    test "matches added direct children and not a file inside a subfolder" do
      expect_folder_lookup("collection_changes_added")
      expect_change_page("collection_changes_added.2", @checkpoint)

      assert {:ok, %{signals: signals, checkpoint: "105"}} =
               poll("google.drive.collection.changes", %{collection_id: @watch_folder})

      assert %{
               collection_match: "yes",
               change_type: "updated",
               removed?: false,
               record: %{created_at: "2026-11-02T09:46:00.962Z", parents: [@watch_folder]}
             } = record_signal(signals, @added)

      assert %{
               collection_match: "yes",
               record: %{
                 mime_type: "application/vnd.google-apps.folder",
                 parents: [@watch_folder]
               }
             } = record_signal(signals, @subfolder)

      assert %{collection_match: "no", record: %{parents: [@subfolder]}} =
               record_signal(signals, @nested)
    end

    test "matches a child moved to the trash and cannot place a removed one" do
      expect_folder_lookup("collection_changes_trashed")
      expect_change_page("collection_changes_trashed.2", @checkpoint)
      expect_change_page("collection_changes_trashed.3", "112")

      assert {:ok, %{signals: [trashed, removed], checkpoint: "113"}} =
               poll("google.drive.collection.changes", %{collection_id: @watch_folder})

      assert %{
               provider_record_id: @trashed,
               collection_match: "yes",
               change_type: "updated",
               removed?: false,
               record: %{trashed?: true, parents: [@watch_folder]}
             } = trashed

      assert removed == %{
               collection_id: @watch_folder,
               collection_match: "unknown",
               provider: "google_drive",
               provider_record_id: @removed,
               change_type: "deleted",
               removed?: true,
               changed_at: "2026-11-02T09:46:54.413Z"
             }
    end
  end

  describe "google.drive.file.changed" do
    test "returns a removal without file metadata as file_id, removed and time" do
      expect_change_page("file_changed_removed", @checkpoint, %{
        "includeItemsFromAllDrives" => "false"
      })

      assert {:ok, %{signals: signals, checkpoint: "105"}} =
               poll("google.drive.file.changed", %{})

      assert file_signal(signals, @added) == %{
               file_id: @added,
               removed: true,
               time: "2026-11-02T09:46:01.724Z",
               change_type: "file"
             }
    end

    test "keeps a trash-only update, a removal and a drive-level change apart" do
      expect_change_page("file_changed_mixed", @checkpoint, %{
        "includeItemsFromAllDrives" => "true",
        "supportsAllDrives" => "true"
      })

      assert {:ok, %{signals: [trashed, removed, drive_change], checkpoint: "113"}} =
               poll("google.drive.file.changed", %{
                 include_items_from_all_drives: true,
                 supports_all_drives: true
               })

      assert %{
               file_id: @trashed,
               removed: false,
               change_type: "file",
               file: %{file_id: @trashed, trashed?: true, parents: [@watch_folder]}
             } = trashed

      assert removed == %{
               file_id: @removed,
               removed: true,
               time: "2026-11-02T09:46:54.413Z",
               change_type: "file"
             }

      assert drive_change == %{
               drive_id: @shared_drive,
               removed: false,
               time: "2026-11-02T09:46:55.839Z",
               change_type: "drive"
             }
    end
  end

  defp poll(trigger_id, config) do
    scopes = ["https://www.googleapis.com/auth/drive.metadata.readonly"]

    connection =
      Connect.Connection.new!(%{
        id: "conn_1",
        provider: :google,
        profile: :user,
        tenant_id: "tenant_1",
        owner_type: :app_user,
        owner_id: "user_1",
        status: :connected,
        scopes: scopes
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
        provider: :google,
        profile: :user,
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
        fields: %{access_token: "token"},
        scopes: scopes
      })

    Connect.poll(Drive.integration(), trigger_id, config,
      context: context,
      credential_lease: lease,
      checkpoint: @checkpoint
    )
  end

  defp expect_folder_lookup(fixture) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v3/files/#{@watch_folder}"
      assert conn.query_params["fields"] == @folder_lookup_fields
      assert conn.query_params["supportsAllDrives"] == "true"
      Req.Test.json(conn, LiveSmoke.fixture!(:google_drive, fixture))
    end)
  end

  defp expect_change_page(fixture, page_token, params \\ %{}) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v3/changes"
      assert conn.query_params["pageToken"] == page_token
      assert conn.query_params["includeRemoved"] == "true"
      assert Map.take(conn.query_params, Map.keys(params)) == params
      Req.Test.json(conn, LiveSmoke.fixture!(:google_drive, fixture))
    end)
  end

  defp file_signal(signals, file_id), do: Enum.find(signals, &(&1[:file_id] == file_id))

  defp record_signal(signals, file_id),
    do: Enum.find(signals, &(&1[:provider_record_id] == file_id))
end
