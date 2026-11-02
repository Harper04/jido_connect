defmodule Jido.Connect.Google.Meet.LiveSmokeTest do
  @moduledoc """
  Live smoke checks against the Google Workspace test account.

      mix test --only live_smoke

  See `docs/live_smoke_tests.md` for the variables and the recording mode.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect.Error.ProviderError
  alias Jido.Connect.Google.Meet.Client

  @tag env!(["GOOGLE_ACCESS_TOKEN"])
  test "lists one page of conference records", %{env: env} do
    LiveSmoke.record(
      {:jido_connect_google, :google_req_options},
      :google_meet,
      "conference_records"
    )

    assert {:ok, result} =
             Client.list_conference_records(%{page_size: 1}, env["GOOGLE_ACCESS_TOKEN"])

    assert is_map(result)
  end

  @tag env!(["GOOGLE_ACCESS_TOKEN", "GOOGLE_MEET_CONFERENCE_RECORD", "GOOGLE_MEET_TRANSCRIPT"])
  test "pages through transcript entries in meeting order", %{env: env} do
    token = env["GOOGLE_ACCESS_TOKEN"]
    transcript = env["GOOGLE_MEET_TRANSCRIPT"]

    # The whole transcript in one request is the reference for the paged walk.
    assert {:ok, %{transcript_entries: reference} = single_page} =
             Client.list_transcript_entries(
               %{transcript_name: transcript, page_size: 100},
               token
             )

    refute Map.has_key?(single_page, :next_page_token)

    LiveSmoke.record(
      {:jido_connect_google, :google_req_options},
      :google_meet,
      "transcript_entries",
      fields: ["text"]
    )

    pages = entry_pages(transcript, token)
    entries = Enum.flat_map(pages, & &1.transcript_entries)

    assert length(pages) >= 2
    assert Enum.all?(pages, &(length(&1.transcript_entries) <= 1))

    assert Enum.map(entries, &attribution/1) == Enum.map(reference, &attribution/1)
    assert length(entries) >= 2

    names = Enum.map(entries, & &1.entry_name)
    assert Enum.uniq(names) == names
    assert Enum.all?(names, &String.starts_with?(&1, transcript <> "/entries/"))

    participant_prefix = env["GOOGLE_MEET_CONFERENCE_RECORD"] <> "/participants/"
    assert Enum.all?(entries, &String.starts_with?(&1.participant, participant_prefix))

    starts = Enum.map(entries, &timestamp!(&1.start_time))
    assert starts == Enum.sort(starts, DateTime)

    for entry <- entries do
      assert DateTime.compare(timestamp!(entry.start_time), timestamp!(entry.end_time)) != :gt
      assert is_binary(entry.language_code)
      assert is_binary(entry.text) and entry.text != ""
    end
  end

  @tag env!(["GOOGLE_ACCESS_TOKEN", "GOOGLE_MEET_CONFERENCE_RECORD"])
  test "rejects the entries of a missing transcript", %{env: env} do
    missing =
      env["GOOGLE_MEET_CONFERENCE_RECORD"] <>
        "/transcripts/00000000-0000-0000-0000-000000000000"

    LiveSmoke.record(
      {:jido_connect_google, :google_req_options},
      :google_meet,
      "transcript_entries_not_found"
    )

    assert {:error, %ProviderError{provider: :google, reason: :http_error, status: 404}} =
             Client.list_transcript_entries(
               %{transcript_name: missing, page_size: 1},
               env["GOOGLE_ACCESS_TOKEN"]
             )
  end

  defp entry_pages(transcript, token, page_token \\ nil, pages \\ []) do
    params = %{transcript_name: transcript, page_size: 1, page_token: page_token}
    assert {:ok, page} = Client.list_transcript_entries(params, token)
    pages = [page | pages]

    case page do
      %{next_page_token: next} when is_binary(next) -> entry_pages(transcript, token, next, pages)
      _last -> Enum.reverse(pages)
    end
  end

  defp attribution(entry), do: {entry.entry_name, entry.participant, entry.start_time}

  defp timestamp!(value) do
    {:ok, timestamp, 0} = DateTime.from_iso8601(value)
    timestamp
  end
end
