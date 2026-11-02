defmodule Jido.Connect.Tempo.Client.WorklogsTest do
  use ExUnit.Case, async: false

  alias Jido.Connect.{Connection, Error}
  alias Jido.Connect.Tempo.{Client, Fixture, Worklog}
  alias Jido.Connect.Tempo.Client.Request

  # The recorded October read of the test user from the foundation: 50
  # worklogs with a `next` link on the first page, 5 without one on the
  # second. The sanitizer replaced the test user's account ID with
  # `account-1`, also in the `next` links.
  @account "account-1"
  @path "/4/worklogs/user/account-1"
  @october [from: "2026-10-01", to: "2026-10-31"]

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous = Application.fetch_env(:jido_connect_tempo, :tempo_req_options)
    Application.put_env(:jido_connect_tempo, :tempo_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jido_connect_tempo, :tempo_req_options, value)
        :error -> Application.delete_env(:jido_connect_tempo, :tempo_req_options)
      end
    end)
  end

  describe "list_own_worklogs/2" do
    test "reads every page of the inclusive range for the connection's account" do
      test_pid = self()

      Req.Test.expect(__MODULE__, 2, fn conn ->
        query = URI.decode_query(conn.query_string)
        send(test_pid, {:page, conn.host, conn.request_path, query})

        case query["offset"] do
          "0" -> Fixture.respond(conn, "worklogs_page")
          "50" -> Fixture.respond(conn, "worklogs_page.2")
        end
      end)

      assert {:ok, worklogs} = Client.list_own_worklogs(request(), @october)
      assert length(worklogs) == 55
      assert Enum.all?(worklogs, &match?(%Worklog{author_account_id: @account}, &1))

      assert Enum.map(worklogs, & &1.tempo_worklog_id) ==
               Enum.map(
                 recorded("worklogs_page") ++ recorded("worklogs_page.2"),
                 & &1["tempoWorklogId"]
               )

      for offset <- ["0", "50"] do
        assert_received {:page, "api.us.tempo.io", @path, query}

        assert query == %{
                 "from" => "2026-10-01",
                 "to" => "2026-10-31",
                 "offset" => offset,
                 "limit" => "50"
               }
      end
    end

    test "keeps every field of a recorded worklog" do
      expect_pages(["worklogs_page", "worklogs_page.2"])

      assert {:ok, [first | _rest]} = Client.list_own_worklogs(request(), @october)

      assert first == %Worklog{
               tempo_worklog_id: 79_097,
               author_account_id: @account,
               start_date: "2026-10-01",
               time_spent_seconds: 5400,
               issue_id: 46_097,
               description: "JCL live seed worklog: open period, first day",
               work_attributes: [],
               start_time: "09:00:00",
               start_date_time_utc: "2026-10-01T07:00:00Z",
               billable_seconds: 5400,
               created_at: "2026-10-30T19:19:07Z",
               updated_at: "2026-10-30T19:22:34Z",
               self: "https://api.tempo.io/4/worklogs/79097"
             }
    end

    # The recorded first page emptied, as Tempo answers a range without
    # worklogs.
    test "sends the account ID as one encoded path segment" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/4/worklogs/user/557058%3Af0e1%2Fa%20b"
        Fixture.respond(conn, "worklogs_page", body: &empty_page/1)
      end)

      assert {:ok, []} = Client.list_own_worklogs(request("557058:f0e1/a b"), @october)
    end
  end

  describe "a read fails as a whole" do
    test "when a later page fails" do
      Req.Test.expect(__MODULE__, 2, fn conn ->
        case URI.decode_query(conn.query_string)["offset"] do
          "0" -> Fixture.respond(conn, "worklogs_page")
          "50" -> Fixture.respond(conn, "worklogs_page.2", status: 503)
        end
      end)

      assert {:error, %Error.ProviderError{reason: :server_error, status: 503}} =
               Client.list_own_worklogs(request(), @october)
    end

    test "when a later page is malformed" do
      Req.Test.expect(__MODULE__, 2, fn conn ->
        case URI.decode_query(conn.query_string)["offset"] do
          "0" -> Fixture.respond(conn, "worklogs_page")
          "50" -> Fixture.respond(conn, "worklogs_page.2", body: &Map.delete(&1, "metadata"))
        end
      end)

      assert {:error, %Error.ProviderError{reason: :invalid_pagination}} =
               Client.list_own_worklogs(request(), @october)
    end

    test "when a worklog of another account is on a later page" do
      expect_pages(["worklogs_page", "worklogs_page.2"],
        last: &put_in(&1, ["author", "accountId"], "account-2")
      )

      assert {:error,
              %Error.ProviderError{
                reason: :foreign_worklog_author,
                details: %{tempo_worklog_id: 79_130} = details
              }} = Client.list_own_worklogs(request(), @october)

      refute inspect(details) =~ "account-2"
    end

    test "when a booking day lies outside the range" do
      for day <- ["2026-09-30", "2026-11-01"] do
        expect_pages(["worklogs_page", "worklogs_page.2"], last: &Map.put(&1, "startDate", day))

        assert {:error,
                %Error.ProviderError{
                  reason: :worklog_outside_range,
                  details: %{tempo_worklog_id: 79_130, start_date: ^day}
                }} = Client.list_own_worklogs(request(), @october)
      end
    end
  end

  describe "normalization" do
    # The last recorded worklog with one field removed or broken.
    test "a worklog without Tempo ID, author, booking date, duration or issue ID fails the read" do
      for {change, field} <- [
            {&Map.delete(&1, "tempoWorklogId"), "tempoWorklogId"},
            {&Map.put(&1, "tempoWorklogId", "79130"), "tempoWorklogId"},
            {&Map.delete(&1, "author"), "author.accountId"},
            {&put_in(&1, ["author", "accountId"], ""), "author.accountId"},
            {&Map.put(&1, "author", "account-1"), "author.accountId"},
            {&Map.delete(&1, "startDate"), "startDate"},
            {&Map.put(&1, "startDate", "2026-10-32"), "startDate"},
            {&Map.delete(&1, "timeSpentSeconds"), "timeSpentSeconds"},
            {&Map.put(&1, "timeSpentSeconds", 329.5), "timeSpentSeconds"},
            {&Map.put(&1, "timeSpentSeconds", "329"), "timeSpentSeconds"},
            {&Map.delete(&1, "issue"), "issue.id"},
            {&put_in(&1, ["issue", "id"], "46097"), "issue.id"}
          ] do
        expect_pages(["worklogs_page", "worklogs_page.2"], last: change)

        assert {:error,
                %Error.ProviderError{
                  reason: :invalid_worklog,
                  details: %{field: ^field}
                } = error} = Client.list_own_worklogs(request(), @october)

        refute inspect(error) =~ "JCL live seed worklog"
      end
    end

    test "an optional field of the wrong type fails the read" do
      for {change, field} <- [
            {&Map.put(&1, "description", 5), "description"},
            {&Map.put(&1, "billableSeconds", -1), "billableSeconds"},
            {&Map.put(&1, "startTime", "25:00:00"), "startTime"},
            {&Map.put(&1, "startDateTimeUtc", "yesterday"), "startDateTimeUtc"},
            {&put_in(&1, ["attributes", "values"], [%{"value" => "x"}]), "attributes.values"},
            {&put_in(&1, ["attributes", "values"], %{}), "attributes.values"}
          ] do
        expect_pages(["worklogs_page", "worklogs_page.2"], last: change)

        assert {:error, %Error.ProviderError{reason: :invalid_worklog, details: %{field: ^field}}} =
                 Client.list_own_worklogs(request(), @october)
      end
    end

    test "an absent description stays nil and an empty one stays empty" do
      expect_pages(["worklogs_page", "worklogs_page.2"],
        first: &Map.put(&1, "description", ""),
        last: &Map.delete(&1, "description")
      )

      assert {:ok, worklogs} = Client.list_own_worklogs(request(), @october)
      assert %Worklog{tempo_worklog_id: 79_097, description: ""} = List.first(worklogs)
      assert %Worklog{tempo_worklog_id: 79_130, description: nil} = List.last(worklogs)
    end

    test "zero billable seconds stay zero" do
      expect_pages(["worklogs_page", "worklogs_page.2"])

      assert {:ok, worklogs} = Client.list_own_worklogs(request(), @october)

      assert %Worklog{billable_seconds: 0, time_spent_seconds: 900} =
               Enum.find(worklogs, &(&1.tempo_worklog_id == 79_101))
    end

    test "optional fields that Tempo leaves out stay nil" do
      optional =
        ~w(startTime startDateTimeUtc billableSeconds createdAt updatedAt self attributes)

      expect_pages(["worklogs_page", "worklogs_page.2"], last: &Map.drop(&1, optional))

      assert {:ok, worklogs} = Client.list_own_worklogs(request(), @october)

      assert %Worklog{
               tempo_worklog_id: 79_130,
               work_attributes: [],
               start_time: nil,
               start_date_time_utc: nil,
               billable_seconds: nil,
               created_at: nil,
               updated_at: nil,
               self: nil
             } = List.last(worklogs)
    end

    # The test site has work attributes only around a TEMPO-L2 run, so no
    # recording holds a value; the pairs follow Tempo's OpenAPI shape.
    test "work attribute values keep their key and value" do
      values = [%{"key" => "_JclPhase_", "value" => "Build"}, %{"key" => "_JclHours_"}]

      expect_pages(["worklogs_page", "worklogs_page.2"],
        last: &put_in(&1, ["attributes", "values"], values)
      )

      assert {:ok, worklogs} = Client.list_own_worklogs(request(), @october)

      assert List.last(worklogs).work_attributes == [
               %{key: "_JclPhase_", value: "Build"},
               %{key: "_JclHours_", value: nil}
             ]
    end
  end

  describe "the range" do
    test "an invalid or reversed range fails before any request" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, :requested)
        Fixture.respond(conn, "worklogs_page")
      end)

      for {opts, field} <- [
            {[from: "2026-10-32", to: "2026-10-31"], :from},
            {[from: "2026/10/01", to: "2026-10-31"], :from},
            {[from: "+2026-10-01", to: "2026-10-31"], :from},
            {[from: "20261001", to: "2026-10-31"], :from},
            {[from: ~D[2026-10-01], to: "2026-10-31"], :from},
            {[to: "2026-10-31"], :from},
            {[from: "2026-10-01", to: ""], :to},
            {[from: "2026-10-01"], :to},
            {[from: "2026-10-02", to: "2026-10-01"], :to}
          ] do
        assert {:error,
                %Error.ValidationError{
                  reason: :invalid_date_range,
                  subject: ^field,
                  details: %{field: ^field}
                }} = Client.list_own_worklogs(request(), opts)
      end

      refute_received :requested
    end

    test "a one-day range sends the same day as from and to" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert %{"from" => "2026-10-31", "to" => "2026-10-31"} =
                 URI.decode_query(conn.query_string)

        Fixture.respond(conn, "worklogs_page", body: &empty_page/1)
      end)

      assert {:ok, []} = Client.list_own_worklogs(request(), from: "2026-10-31", to: "2026-10-31")
    end

    test "never sends updatedFrom or other query parameters of the caller" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.query_string |> URI.decode_query() |> Map.keys() |> Enum.sort() ==
                 ["from", "limit", "offset", "to"]

        Fixture.respond(conn, "worklogs_page", body: &empty_page/1)
      end)

      assert {:ok, []} =
               Client.list_own_worklogs(
                 request(),
                 @october ++ [params: [updatedFrom: "2026-10-30"], updatedFrom: "2026-10-30"]
               )
    end

    test "passes the page size and the read bounds to the pagination" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert URI.decode_query(conn.query_string)["limit"] == "2"
        Fixture.respond(conn, "worklogs_page")
      end)

      assert {:error, %Error.ProviderError{reason: :result_limit_exceeded}} =
               Client.list_own_worklogs(request(), @october ++ [limit: 2, max_results: 10])
    end
  end

  # Answers each page request with the recorded page for its offset. `:first`
  # changes the first worklog of the first page, `:last` the last worklog of
  # the last page.
  defp expect_pages(names, opts \\ []) do
    first = Keyword.get(opts, :first, & &1)
    last = Keyword.get(opts, :last, & &1)
    pages = length(names)

    Req.Test.expect(__MODULE__, pages, fn conn ->
      index = div(String.to_integer(URI.decode_query(conn.query_string)["offset"]), 50)

      change = fn body ->
        body
        |> then(&if(index == 0, do: update_result(&1, 0, first), else: &1))
        |> then(&if(index == pages - 1, do: update_result(&1, -1, last), else: &1))
      end

      Fixture.respond(conn, Enum.at(names, index), body: change)
    end)
  end

  defp update_result(body, position, fun),
    do: update_in(body, ["results"], &List.update_at(&1, position, fun))

  defp empty_page(body) do
    body
    |> Map.put("results", [])
    |> update_in(["metadata"], &(&1 |> Map.put("count", 0) |> Map.delete("next")))
  end

  defp recorded(name), do: Fixture.recorded!(name)["body"]["results"]

  defp request(account_id \\ @account) do
    connection =
      Connection.new!(%{
        id: "tempo_conn_1",
        provider: :tempo,
        profile: :api_token,
        tenant_id: "tenant_1",
        owner_type: :app_user,
        owner_id: "user_1",
        subject: %{account_id: account_id},
        status: :connected,
        scopes: ["tempo.worklogs.read"],
        metadata: %{api_origin: "https://api.us.tempo.io"}
      })

    {:ok, request} = Request.new(connection, %{api_token: "tempo-api-token-272"})
    request
  end
end
