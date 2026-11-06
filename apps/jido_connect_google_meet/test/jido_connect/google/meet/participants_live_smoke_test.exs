defmodule Jido.Connect.Google.Meet.ParticipantsLiveSmokeTest do
  @moduledoc """
  Live checks that resolve the speakers of the prepared transcript entries
  into conference participants through the participant actions.

      mix test --only live_smoke

  The checks need the Meet data prepared on 2026-10-30:
  `GOOGLE_MEET_TRANSCRIPT` and its conference record
  `GOOGLE_MEET_CONFERENCE_RECORD`, and the earlier conference record in the
  same space, which ended in the same window between 16:00 and 18:00 UTC and
  has two participants. Google deletes this data 30 days after the
  conferences ended; from then on `LiveMeet.prepared!/1` skips the checks
  that need it. The earlier record is found through the window and expires
  with the prepared one, so its check is skipped on the prepared record's
  answer. See `docs/live_smoke_tests.md` for the variables and the recording
  mode.

  The earlier record's participants include a person outside the test
  account. The sanitizer replaces display names and Google user IDs in the
  recordings; the assertions here compare resource names and never print a
  display name.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect
  alias Jido.Connect.Error.ProviderError
  alias Jido.Connect.Google.Meet
  alias Jido.Connect.Google.Meet.Client
  alias Jido.Connect.Google.Meet.TestSupport.LiveMeet

  require LiveMeet

  @req_options {:jido_connect_google, :google_req_options}
  @readonly_scope "https://www.googleapis.com/auth/meetings.space.readonly"

  # The prepared conference records ended inside this window.
  @prepared_window_start ~U[2026-10-30 16:00:00Z]
  @prepared_window_end ~U[2026-10-30 18:00:00Z]

  # Google returns at most 100 transcript entries per page.
  @entry_page_size 100
  @page_limit 10

  @user_types ["signed_in_user", "anonymous_user", "phone_user"]

  @tag LiveMeet.prepared!([
         "GOOGLE_ACCESS_TOKEN",
         "GOOGLE_MEET_CONFERENCE_RECORD",
         "GOOGLE_MEET_TRANSCRIPT"
       ])
  @tag timeout: :timer.minutes(2)
  test "resolves every speaker of the prepared transcript entries", %{env: env} do
    token = env["GOOGLE_ACCESS_TOKEN"]
    record = env["GOOGLE_MEET_CONFERENCE_RECORD"]

    speakers =
      env["GOOGLE_MEET_TRANSCRIPT"]
      |> entries(token)
      |> Enum.map(& &1.participant)
      |> Enum.uniq()

    assert speakers != [], "the prepared transcript has no entries"

    assert {:ok, %{participants: participants} = page} =
             invoke("google.meet.participant.list", %{conference_record_name: record}, token)

    refute Map.has_key?(page, :next_page_token)
    names = Enum.map(participants, & &1.participant_name)
    assert speakers -- names == []

    LiveSmoke.record(@req_options, :google_meet, "participant_get")

    for speaker <- speakers do
      assert {:ok, %{participant: participant}} =
               invoke("google.meet.participant.get", %{participant_name: speaker}, token)

      assert participant == Enum.find(participants, &(&1.participant_name == speaker))
      assert_identity(participant)
    end

    # A field projection leaves everything but the name out of the response.
    LiveSmoke.record(@req_options, :google_meet, "participant_get_name_only")
    [speaker | _rest] = speakers

    assert {:ok, %{participant: named}} =
             invoke(
               "google.meet.participant.get",
               %{participant_name: speaker, fields: "name"},
               token
             )

    assert named.participant_name == speaker
    assert {named.user_type, named.user, named.display_name} == {nil, nil, nil}
  end

  @tag LiveMeet.prepared!(["GOOGLE_ACCESS_TOKEN", "GOOGLE_MEET_CONFERENCE_RECORD"])
  @tag timeout: :timer.minutes(2)
  test "pages through the participants of the earlier prepared conference record", %{env: env} do
    token = env["GOOGLE_ACCESS_TOKEN"]
    earlier = earlier_record!(env["GOOGLE_MEET_CONFERENCE_RECORD"], token)

    assert {:ok, %{participants: reference} = page} =
             invoke(
               "google.meet.participant.list",
               %{conference_record_name: earlier, page_size: 100},
               token
             )

    refute Map.has_key?(page, :next_page_token)

    # The page token encodes the next participant's Google user ID in Base64,
    # where the sanitizer does not look, so the recording keeps a placeholder.
    LiveSmoke.record(@req_options, :google_meet, "participants", fields: ["nextPageToken"])

    pages = participant_pages(earlier, token)
    participants = Enum.flat_map(pages, & &1.participants)
    names = Enum.map(participants, & &1.participant_name)

    assert length(pages) >= 2
    assert Enum.all?(pages, &(length(&1.participants) == 1))
    assert names == Enum.map(reference, & &1.participant_name)
    assert Enum.uniq(names) == names
    assert Enum.all?(names, &String.starts_with?(&1, earlier <> "/participants/"))

    for participant <- participants do
      assert_identity(participant)
    end
  end

  @tag LiveMeet.prepared!(["GOOGLE_ACCESS_TOKEN", "GOOGLE_MEET_CONFERENCE_RECORD"])
  test "rejects a missing participant of the prepared conference record", %{env: env} do
    missing =
      env["GOOGLE_MEET_CONFERENCE_RECORD"] <>
        "/participants/00000000-0000-0000-0000-000000000000"

    LiveSmoke.record(@req_options, :google_meet, "participant_not_found")

    assert {:error, %ProviderError{provider: :google, reason: :http_error, status: 404}} =
             invoke(
               "google.meet.participant.get",
               %{participant_name: missing},
               env["GOOGLE_ACCESS_TOKEN"]
             )
  end

  @tag env!(["GOOGLE_ACCESS_TOKEN"])
  test "rejects the participants of an invalid conference record", %{env: env} do
    LiveSmoke.record(@req_options, :google_meet, "participants_invalid_record")

    assert {:error, %ProviderError{provider: :google, reason: :http_error, status: 400}} =
             invoke(
               "google.meet.participant.list",
               %{conference_record_name: "conferenceRecords/not-a-conference", page_size: 1},
               env["GOOGLE_ACCESS_TOKEN"]
             )
  end

  defp assert_identity(participant) do
    assert participant.user_type in @user_types
    assert is_binary(participant.display_name) and participant.display_name != ""

    if participant.user_type == "signed_in_user" do
      assert "users/" <> _id = participant.user
    end
  end

  defp earlier_record!(prepared, token) do
    window =
      ~s(end_time>="#{DateTime.to_iso8601(@prepared_window_start)}" AND ) <>
        ~s(end_time<="#{DateTime.to_iso8601(@prepared_window_end)}")

    assert {:ok, %{conference_records: records}} =
             Client.list_conference_records(%{filter: window, page_size: 100}, token)

    assert [earlier] = Enum.map(records, & &1.conference_record_name) -- [prepared]
    earlier
  end

  defp entries(transcript, token, page_token \\ nil, pages \\ 0) do
    assert pages < @page_limit, "the prepared transcript has too many entries"
    params = %{transcript_name: transcript, page_size: @entry_page_size, page_token: page_token}
    assert {:ok, page} = Client.list_transcript_entries(params, token)

    case page do
      %{next_page_token: next} when is_binary(next) ->
        page.transcript_entries ++ entries(transcript, token, next, pages + 1)

      _last ->
        page.transcript_entries
    end
  end

  # Follows next_page_token one participant per page and fails past the limit.
  defp participant_pages(record, token, page_token \\ nil, pages \\ []) do
    assert length(pages) < @page_limit, "the conference record has too many participants"
    # The action's schema takes a page token only as a string.
    input =
      %{conference_record_name: record, page_size: 1, page_token: page_token}
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    assert {:ok, page} = invoke("google.meet.participant.list", input, token)
    pages = [page | pages]

    case page do
      %{next_page_token: next} when is_binary(next) ->
        participant_pages(record, token, next, pages)

      _last ->
        Enum.reverse(pages)
    end
  end

  defp invoke(action_id, input, token) do
    connection =
      Connect.Connection.new!(%{
        id: "live_conn",
        provider: :google,
        profile: :user,
        tenant_id: "live_tenant",
        owner_type: :app_user,
        owner_id: "live_user",
        status: :connected,
        scopes: [@readonly_scope]
      })

    context =
      Connect.Context.new!(%{
        tenant_id: "live_tenant",
        actor: %{id: "live_user", type: :user},
        connection: connection
      })

    lease =
      Connect.CredentialLease.new!(%{
        connection_id: "live_conn",
        provider: :google,
        profile: :user,
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
        fields: %{access_token: token},
        scopes: [@readonly_scope]
      })

    Connect.invoke(Meet.integration(), action_id, input,
      context: context,
      credential_lease: lease
    )
  end
end
