defmodule Jido.Connect.Google.Calendar.TestSupport.LiveCalendar do
  @moduledoc false

  # Runs Calendar actions and the event poll through `Jido.Connect` with a
  # connection and a credential lease around a live access token, so live
  # smoke tests exercise the DSL, the scope check and the handlers, not only
  # the client. The declared scopes gate the runtime check; the token itself
  # may carry broader Google scopes.

  alias Jido.Connect
  alias Jido.Connect.Google.Calendar
  alias Jido.Connect.Google.Calendar.Client
  alias Jido.Connect.TestSupport.LiveSmoke

  @events_readonly_scope "https://www.googleapis.com/auth/calendar.events.readonly"
  @events_scope "https://www.googleapis.com/auth/calendar.events"

  # htmlLink carries the event ID and the calendar owner's address in Base64,
  # which the sanitizer does not decode. Meet entry points carry dial-in PINs,
  # also inside the `more` link, so their `uri` goes too; hangoutLink stays.
  @record_fields ["htmlLink", "pin", "uri"]

  def events_readonly_scope, do: @events_readonly_scope
  def events_scope, do: @events_scope

  @doc "Records the Calendar responses of the current test under `name`."
  def record(name) do
    LiveSmoke.record({:jido_connect_google, :google_req_options}, :google_calendar, name,
      fields: @record_fields
    )
  end

  @doc "Invokes a Calendar action with `scopes` on both the connection and the lease."
  def invoke(action_id, input, access_token, scopes) do
    {context, lease} = context_and_lease(access_token, scopes)

    Connect.invoke(Calendar.integration(), action_id, input,
      context: context,
      credential_lease: lease
    )
  end

  @doc "Runs `google.calendar.event.changed` once under the trigger's read-only scope."
  def poll(config, checkpoint, access_token) do
    {context, lease} = context_and_lease(access_token, [@events_readonly_scope])

    Connect.poll(Calendar.integration(), "google.calendar.event.changed", config,
      context: context,
      credential_lease: lease,
      checkpoint: checkpoint
    )
  end

  defp context_and_lease(access_token, scopes) do
    connection =
      Connect.Connection.new!(%{
        id: "live-calendar",
        provider: :google,
        profile: :user,
        tenant_id: "live",
        owner_type: :app_user,
        owner_id: "live-test-user",
        status: :connected,
        scopes: scopes
      })

    context =
      Connect.Context.new!(%{
        tenant_id: "live",
        actor: %{id: "live-test-user", type: :user},
        connection: connection
      })

    lease =
      Connect.CredentialLease.new!(%{
        connection_id: connection.id,
        provider: :google,
        profile: :user,
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
        fields: %{access_token: access_token},
        scopes: scopes
      })

    {context, lease}
  end

  @doc "Returns a per-run suffix in base32hex, the alphabet of Calendar event IDs."
  def run_id do
    5
    |> :crypto.strong_rand_bytes()
    |> Base.hex_encode32(case: :lower, padding: false)
  end

  @doc "Deletes an event without notifications and ignores the result, for cleanup."
  def delete_quietly(calendar_id, event_id, access_token) do
    _result =
      Client.delete_event(
        %{calendar_id: calendar_id, event_id: event_id, send_updates: "none"},
        access_token
      )

    :ok
  end
end
