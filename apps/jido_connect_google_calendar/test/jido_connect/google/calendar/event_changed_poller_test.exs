defmodule Jido.Connect.Google.Calendar.EventChangedPollerTest do
  @moduledoc """
  Polls `google.calendar.event.changed` through `Jido.Connect.poll/4` and the
  real Calendar client against `Req.Test`, replaying responses recorded from
  the Google Workspace test account.
  """

  use ExUnit.Case, async: false

  alias Jido.Connect
  alias Jido.Connect.Error.ProviderError
  alias Jido.Connect.Google.Calendar
  alias Jido.Connect.TestSupport.LiveSmoke

  @trigger_id "google.calendar.event.changed"
  @calendar_id "primary"

  setup {Req.Test, :verify_on_exit!}

  setup do
    Application.put_env(
      :jido_connect_google_calendar,
      :google_calendar_api_base_url,
      "https://calendar.test"
    )

    Application.put_env(:jido_connect_google, :google_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:jido_connect_google_calendar, :google_calendar_api_base_url)
      Application.delete_env(:jido_connect_google, :google_req_options)
    end)
  end

  describe "a final page without nextSyncToken" do
    test "fails an incremental poll instead of keeping the old checkpoint" do
      # Derived: the recorded incremental page with its nextSyncToken removed.
      page = "event_changed_created" |> recorded() |> Map.delete("nextSyncToken")

      Req.Test.expect(__MODULE__, &Req.Test.json(&1, page))

      assert {:error, %ProviderError{reason: :invalid_response}} =
               poll(%{calendar_id: @calendar_id}, "sync-1")
    end
  end

  defp recorded(name), do: LiveSmoke.fixture!(:google_calendar, name)

  defp poll(config, checkpoint) do
    {context, lease} = context_and_lease()

    Connect.poll(Calendar.integration(), @trigger_id, config,
      context: context,
      credential_lease: lease,
      checkpoint: checkpoint
    )
  end

  defp context_and_lease do
    scopes = ["https://www.googleapis.com/auth/calendar.events.readonly"]

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

    {context, lease}
  end
end
