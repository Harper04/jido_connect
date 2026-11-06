defmodule Jido.Connect.Google.Meet.LiveMeetTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Jido.Connect.Google.Meet.TestSupport.LiveMeet
  alias Jido.Connect.TestSupport.LiveSmoke

  require LiveMeet

  @record "conferenceRecords/rec-1"
  @transcript "conferenceRecords/rec-1/transcripts/tr-1"
  @names ["GOOGLE_ACCESS_TOKEN", "GOOGLE_MEET_CONFERENCE_RECORD", "GOOGLE_MEET_TRANSCRIPT"]
  @env %{
    "GOOGLE_ACCESS_TOKEN" => "live-meet-test-token",
    "GOOGLE_MEET_CONFERENCE_RECORD" => @record,
    "GOOGLE_MEET_TRANSCRIPT" => @transcript
  }

  setup do
    Application.put_env(:jido_connect_google_meet, :google_meet_api_base_url, "https://meet.test")
    Application.put_env(:jido_connect_google, :google_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:jido_connect_google_meet, :google_meet_api_base_url)
      Application.delete_env(:jido_connect_google, :google_req_options)
    end)
  end

  test "skips a live run whose prepared transcript Google no longer serves" do
    # Derived: Google's answer for the expired entries cannot be recorded before
    # they expire, so the recorded answer for a missing transcript stands in.
    gone = LiveSmoke.fixture!(:google_meet, "transcript_entries_not_found")

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer live-meet-test-token"]

      case conn.request_path do
        "/v2/conferenceRecords/rec-1" ->
          assert conn.query_params == %{"fields" => "name"}
          Req.Test.json(conn, %{"name" => @record})

        "/v2/conferenceRecords/rec-1/transcripts/tr-1/entries" ->
          assert conn.query_params == %{"pageSize" => "1"}
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(gone)
      end
    end)

    {tags, output} = live_run(fn -> LiveMeet.prepared!(@names) end)

    assert tags[:live_env] == @names
    assert tags[:skip] =~ "GOOGLE_MEET_TRANSCRIPT"
    assert tags[:skip] =~ "prepared on 2026-10-30"
    assert tags[:skip] =~ "404 NOT_FOUND TRANSCRIPT_NOT_FOUND"
    refute tags[:skip] =~ @transcript
    assert output =~ "live_smoke skip test/jido_connect/google/meet/live_meet_test.exs:"
    assert output =~ tags[:skip]
  end

  test "skips a live run whose prepared conference record Google no longer serves" do
    # Derived: the recorded answer for a missing participant stands in for the
    # expired record, whose answer cannot be recorded before it expires.
    gone = LiveSmoke.fixture!(:google_meet, "participant_not_found")

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v2/conferenceRecords/rec-1"
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(gone)
    end)

    {tags, _output} =
      live_run(fn ->
        LiveMeet.prepared!(["GOOGLE_ACCESS_TOKEN", "GOOGLE_MEET_CONFERENCE_RECORD"])
      end)

    assert tags[:skip] =~ "GOOGLE_MEET_CONFERENCE_RECORD"
    assert tags[:skip] =~ "prepared on 2026-10-30"
    assert tags[:skip] =~ "404 NOT_FOUND PARTICIPANT_NOT_FOUND"
  end

  test "checks a run that selects a test of the calling file by location" do
    # `mix test --only live_smoke file:line` includes only the location.
    gone = LiveSmoke.fixture!(:google_meet, "participant_not_found")

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(gone)
    end)

    here = Path.relative_to_cwd(__ENV__.file)
    names = ["GOOGLE_ACCESS_TOKEN", "GOOGLE_MEET_CONFERENCE_RECORD"]

    {tags, _output} =
      live_run(fn -> LiveMeet.prepared!(names) end, %{}, location: {here, 1})

    assert tags[:skip] =~ "GOOGLE_MEET_CONFERENCE_RECORD"

    Req.Test.stub(__MODULE__, fn _conn -> flunk("Google was called") end)

    assert {[live_env: ^names], ""} =
             live_run(fn -> LiveMeet.prepared!(names) end, %{},
               location: {"test/jido_connect/google/meet/client_test.exs", 1}
             )
  end

  test "runs a live test while Google serves the prepared data" do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/v2/conferenceRecords/rec-1" ->
          Req.Test.json(conn, %{"name" => @record})

        "/v2/conferenceRecords/rec-1/transcripts/tr-1/entries" ->
          Req.Test.json(conn, LiveSmoke.fixture!(:google_meet, "transcript_entries"))
      end
    end)

    assert {[live_env: @names], ""} = live_run(fn -> LiveMeet.prepared!(@names) end)
  end

  test "leaves other provider errors to the live test, which then fails on them" do
    invalid = LiveSmoke.fixture!(:google_meet, "participants_invalid_record")

    for {status, body} <- [{400, invalid}, {401, %{"error" => %{"status" => "UNAUTHENTICATED"}}}] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end)

      assert {[live_env: @names], ""} = live_run(fn -> LiveMeet.prepared!(@names) end)
    end
  end

  test "never calls Google outside a live run or without its variables" do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("Google was called") end)

    include = ExUnit.configuration()[:include]

    with_env(@env, fn ->
      try do
        ExUnit.configure(include: [])
        assert LiveMeet.prepared!(@names) == [live_env: @names]
      after
        ExUnit.configure(include: include)
      end
    end)

    {tags, output} =
      live_run(fn -> LiveMeet.prepared!(@names) end, %{"GOOGLE_MEET_TRANSCRIPT" => nil})

    assert tags[:skip] =~ "set GOOGLE_MEET_TRANSCRIPT to run this live test"
    refute output =~ "prepared on"
  end

  # Runs `fun` with the test variables set, as a run that includes :live_smoke
  # or the given include.
  defp live_run(fun, env \\ %{}, filter \\ :live_smoke) do
    include = ExUnit.configuration()[:include]

    with_env(Map.merge(@env, env), fn ->
      try do
        ExUnit.configure(include: List.wrap(filter))
        with_io(fun)
      after
        ExUnit.configure(include: include)
      end
    end)
  end

  defp with_env(values, fun) do
    previous = Map.new(values, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(values, fn {name, value} -> put_env(name, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {name, value} -> put_env(name, value) end)
    end
  end

  defp put_env(name, nil), do: System.delete_env(name)
  defp put_env(name, value), do: System.put_env(name, value)
end
