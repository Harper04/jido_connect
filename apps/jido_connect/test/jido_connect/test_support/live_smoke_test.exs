defmodule Jido.Connect.TestSupport.LiveSmokeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Jido.Connect.Provider.Transport
  alias Jido.Connect.TestSupport.LiveSmoke
  alias Jido.Connect.TestSupport.LiveSmoke.{LeakError, Sanitize}

  require LiveSmoke

  @req_key :live_smoke_test_req_options
  @docs Path.expand("../../../../../docs/live_smoke_tests.md", __DIR__)

  defmodule RecordingWebhook do
    def verify_delivery(body, headers, secret, opts) do
      send(self(), {:verify_delivery, body, headers, secret, opts})
      {:ok, :verified}
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "live-smoke-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "env!/1" do
    test "skips with the names of unset variables" do
      with_env(%{"GOOGLE_ACCESS_TOKEN" => nil, "GOOGLE_GMAIL_QUERY" => ""}, fn ->
        tags = LiveSmoke.env!(["GOOGLE_ACCESS_TOKEN", "GOOGLE_GMAIL_QUERY"])

        assert tags[:live_env] == ["GOOGLE_ACCESS_TOKEN", "GOOGLE_GMAIL_QUERY"]
        assert tags[:skip] =~ "GOOGLE_ACCESS_TOKEN"
        assert tags[:skip] =~ "GOOGLE_GMAIL_QUERY"
      end)
    end

    test "leaves the test runnable when every variable is set" do
      with_env(%{"SLACK_BOT_TOKEN" => "xoxb-live-smoke-test"}, fn ->
        assert LiveSmoke.env!(["SLACK_BOT_TOKEN"]) == [live_env: ["SLACK_BOT_TOKEN"]]
      end)
    end

    test "prints the reason with the test location only when the run includes :live_smoke" do
      include = ExUnit.configuration()[:include]

      with_env(%{"GOOGLE_ACCESS_TOKEN" => nil}, fn ->
        assert capture_io(fn -> LiveSmoke.env!(["GOOGLE_ACCESS_TOKEN"]) end) == ""

        try do
          ExUnit.configure(include: [:live_smoke])
          output = capture_io(fn -> LiveSmoke.env!(["GOOGLE_ACCESS_TOKEN"]) end)

          assert output =~ "live_smoke skip test/jido_connect/test_support/live_smoke_test.exs:"
          assert output =~ "set GOOGLE_ACCESS_TOKEN to run this live test"
        after
          ExUnit.configure(include: include)
        end
      end)
    end

    test "rejects variables the convention does not list" do
      assert_raise ArgumentError, ~r/SLACK_BOT_TOKN/, fn -> LiveSmoke.env!(["SLACK_BOT_TOKN"]) end
    end

    test "setup passes the values to the test context" do
      with_env(%{"JIRA_SITE" => "https://example.atlassian.net"}, fn ->
        assert %{env: %{"JIRA_SITE" => "https://example.atlassian.net"}} =
                 LiveSmoke.setup_live_env(%{live_env: ["JIRA_SITE"]})
      end)

      assert LiveSmoke.setup_live_env(%{}) == :ok

      with_env(%{"JIRA_SITE" => ""}, fn ->
        assert_raise ArgumentError, ~r/JIRA_SITE/, fn ->
          LiveSmoke.setup_live_env(%{live_env: ["JIRA_SITE"]})
        end
      end)
    end
  end

  describe "docs/live_smoke_tests.md" do
    test "lists exactly the variables of the convention" do
      documented =
        ~r/^\| `([A-Z0-9_]+)` \|/m
        |> Regex.scan(File.read!(@docs), capture: :all_but_first)
        |> List.flatten()
        |> MapSet.new()

      expected =
        LiveSmoke.variables()
        |> Enum.flat_map(fn {provider, groups} ->
          destructive = "#{provider |> Atom.to_string() |> String.upcase()}_LIVE_DESTRUCTIVE"
          [destructive | groups.credentials ++ groups.settings]
        end)
        |> MapSet.new()

      assert documented == expected
    end
  end

  describe "write!/1" do
    test "skips unless the provider's destructive variable is true" do
      for value <- [nil, "", "false", "1"] do
        with_env(%{"SLACK_LIVE_DESTRUCTIVE" => value}, fn ->
          tags = LiveSmoke.write!(:slack)

          assert tags[:live_write] == :slack
          assert tags[:skip] =~ "SLACK_LIVE_DESTRUCTIVE=true"
        end)
      end

      with_env(%{"SLACK_LIVE_DESTRUCTIVE" => "true"}, fn ->
        assert LiveSmoke.write!(:slack) == [live_write: :slack]
      end)
    end

    test "rejects unknown providers" do
      assert_raise ArgumentError, ~r/:github/, fn -> LiveSmoke.write!(:github) end
    end

    test "setup refuses a write test whose gate is closed" do
      with_env(%{"TEMPO_LIVE_DESTRUCTIVE" => nil}, fn ->
        assert_raise ArgumentError, ~r/TEMPO_LIVE_DESTRUCTIVE=true/, fn ->
          LiveSmoke.setup_live_env(%{live_write: :tempo})
        end
      end)

      assert_raise ArgumentError, ~r/write!\/1/, fn ->
        LiveSmoke.setup_live_env(%{live_write: true})
      end
    end
  end

  describe "sanitize" do
    test "drops auth headers and cookies" do
      headers = %{
        "authorization" => ["Bearer secret"],
        "cookie" => ["sid=1"],
        "set-cookie" => ["sid=2"],
        "x-slack-signature" => ["v0=abc"],
        "x-forwarded-for" => ["203.0.113.7"],
        "content-type" => ["application/json"]
      }

      assert LiveSmoke.sanitize_headers(headers) == %{"content-type" => ["application/json"]}
    end

    test "redacts token fields and keeps Jira issue fields" do
      body = %{
        "access_token" => "ya29.secret",
        "nested" => [%{"refresh_token" => "1//secret", "ok" => true}],
        "fields" => %{"summary" => "Broken build"}
      }

      assert LiveSmoke.sanitize(body) == %{
               "access_token" => "[redacted]",
               "nested" => [%{"refresh_token" => "[redacted]", "ok" => true}],
               "fields" => %{"summary" => "Broken build"}
             }
    end

    test "replaces email addresses and display names with stable placeholders" do
      body = %{
        "attendees" => [
          %{"displayName" => "Ada Lovelace", "email" => "ada@corp.test"},
          %{"displayName" => "Grace Hopper", "email" => "grace@corp.test"}
        ],
        "creator" => %{"email" => "ada@corp.test"},
        "headers" => [
          %{"name" => "From", "value" => "Ada Lovelace <ada@corp.test>"},
          %{"name" => "To", "value" => "Charles Babbage <charles@corp.test>"}
        ],
        "text" => "Ada Lovelace invited Grace Hopper"
      }

      sanitized = LiveSmoke.sanitize(body)

      assert sanitized["attendees"] == [
               %{"displayName" => "Person 1", "email" => "person-1@example.com"},
               %{"displayName" => "Person 2", "email" => "person-2@example.com"}
             ]

      assert sanitized["creator"] == %{"email" => "person-1@example.com"}

      assert sanitized["headers"] == [
               %{"name" => "From", "value" => "Person 1 <person-1@example.com>"},
               %{"name" => "To", "value" => "Person 3 <person-3@example.com>"}
             ]

      assert sanitized["text"] == "Person 1 invited Person 2"

      for original <- ["Ada", "Grace", "Charles", "corp.test"] do
        refute inspect(sanitized) =~ original
      end
    end

    test "replaces configured fields with stable placeholders" do
      body = %{
        "messages" => [
          %{"text" => "first", "ts" => "1"},
          %{"text" => "second", "ts" => "2"},
          %{"text" => "first", "ts" => "3"}
        ],
        "snippet" => %{"lines" => ["a", "b"]}
      }

      assert LiveSmoke.sanitize(body, fields: ["text", "snippet"]) == %{
               "messages" => [
                 %{"text" => "text-1", "ts" => "1"},
                 %{"text" => "text-2", "ts" => "2"},
                 %{"text" => "text-1", "ts" => "3"}
               ],
               "snippet" => %{"lines" => ["snippet-1", "snippet-2"]}
             }
    end

    test "covers map keys, bare addresses, user names and whole words only" do
      body = %{
        "calendars" => %{"ada@corp.test" => %{"busy" => []}},
        "creator" => %{"displayName" => "Admin"},
        "message" => %{
          "username" => "ada.lovelace",
          "text" => "ada lovelace asked the Administrator"
        },
        "to" => "bob@corp.test, Ada Lovelace <ada@corp.test>"
      }

      assert LiveSmoke.sanitize(body) == %{
               "calendars" => %{"person-1@example.com" => %{"busy" => []}},
               "creator" => %{"displayName" => "Person 1"},
               "message" => %{
                 "username" => "Person 2",
                 "text" => "Person 3 asked the Administrator"
               },
               "to" => "person-2@example.com, Person 3 <person-1@example.com>"
             }
    end

    test "keeps keep_keys in form bodies and survives missing bodies and headers" do
      form = "fields=summary&token=xoxp-form-token&note=ada%40corp.test"

      assert {"fields=summary&token=%5Bredacted%5D&note=person-1%40example.com", _state} =
               Sanitize.body(form, "application/x-www-form-urlencoded", Sanitize.new([]))

      capture = %{
        "provider" => "github",
        "captured_at" => 1,
        "headers" => %{"x-github-event" => nil},
        "body" => nil
      }

      assert %{"body" => "", "headers" => %{"x-github-event" => nil}} =
               LiveSmoke.sanitize_capture(capture)
    end

    test "guards credential-shaped variables that the convention does not list" do
      secret = "seed-only-secret-value"

      with_env(%{"LIVE_SMOKE_EXTRA_API_TOKEN" => secret}, fn ->
        assert_raise LeakError, ~r/LIVE_SMOKE_EXTRA_API_TOKEN/, fn ->
          LiveSmoke.sanitize(%{"note" => secret})
        end
      end)
    end

    test "never shows credential values when the sanitizer state is inspected" do
      token = "xoxb-live-smoke-inspect-check"
      refute inspect(Sanitize.new(credentials: [{"SLACK_BOT_TOKEN", token}])) =~ token
    end

    test "fails when a credential variable's value appears, naming only the variable" do
      token = "xoxb-live-smoke-leak-check"

      with_env(%{"SLACK_BOT_TOKEN" => token}, fn ->
        error =
          assert_raise LeakError, fn ->
            LiveSmoke.sanitize(%{"note" => "token is #{token}"})
          end

        assert Exception.message(error) =~ "SLACK_BOT_TOKEN"
        refute Exception.message(error) =~ token
      end)

      refresh = "1//live-smoke-refresh"

      with_env(%{"GOOGLE_REFRESH_TOKEN" => refresh}, fn ->
        for encoded <- [URI.encode_www_form(refresh), Base.encode64(refresh)] do
          assert_raise LeakError, ~r/GOOGLE_REFRESH_TOKEN/, fn ->
            LiveSmoke.sanitize(%{"next" => "https://example.test/?t=#{encoded}"})
          end
        end
      end)
    end
  end

  describe "record/4 and fixture!/3" do
    test "records a stub response that fixture!/3 returns unchanged for Req.Test.json/2", %{
      tmp: tmp
    } do
      body = %{"id" => "user-1", "items" => [%{"kind" => "label", "count" => 2}], "ok" => true}
      base_url = start_stub([{200, body}, {200, %{"page" => 2}}])

      with_env(%{"JIDO_CONNECT_RECORD" => "1"}, fn ->
        put_req_options(retry: false)
        assert :ok = LiveSmoke.record({:jido_connect, @req_key}, :stub, "profile", root: tmp)
        assert Application.get_env(:jido_connect, @req_key)[:adapter] == LiveSmoke.Recorder

        assert {:ok, %Req.Response{status: 200, body: ^body}} = get(base_url, "/v1/profile")

        assert {:ok, %Req.Response{body: %{"page" => 2}}} =
                 get(base_url, "/v1/calendars/ada%40corp.test")
      end)

      recorded = Path.join(tmp, "test/fixtures/stub/recorded/profile.json")
      envelope = recorded |> File.read!() |> Jason.decode!()

      assert envelope["status"] == 200
      assert envelope["request"] == %{"method" => "GET", "path" => "/v1/profile"}
      assert envelope["recorded_at"] == Date.to_iso8601(Date.utc_today())
      assert envelope["headers"]["content-type"] == ["application/json"]
      refute Map.has_key?(envelope["headers"], "set-cookie")
      refute File.read!(recorded) =~ "stub-access-token"

      assert LiveSmoke.fixture!(:stub, "profile", root: tmp) == body
      assert LiveSmoke.fixture!(:stub, "profile.2", root: tmp) == %{"page" => 2}

      second = Path.join(tmp, "test/fixtures/stub/recorded/profile.2.json")

      assert %{"path" => "/v1/calendars/person-1@example.com"} =
               second |> File.read!() |> Jason.decode!() |> Map.fetch!("request")

      fixture = LiveSmoke.fixture!(:stub, "profile", root: tmp)
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, fixture))
      put_req_options(plug: {Req.Test, __MODULE__})

      assert {:ok, %Req.Response{status: 200, body: ^body}} =
               get("http://stub.test", "/v1/profile")
    end

    test "fails the recording when a credential value appears in the response", %{tmp: tmp} do
      token = "ya29.live-smoke-recorded-leak"
      base_url = start_stub([{200, %{"echo" => token}}])

      with_env(%{"JIDO_CONNECT_RECORD" => "1", "GOOGLE_ACCESS_TOKEN" => token}, fn ->
        put_req_options(retry: false)
        :ok = LiveSmoke.record({:jido_connect, @req_key}, :stub, "leak", root: tmp)

        error = assert_raise LeakError, fn -> get(base_url, "/v1/echo") end
        assert Exception.message(error) =~ "GOOGLE_ACCESS_TOKEN"
        refute Exception.message(error) =~ token
      end)

      refute File.exists?(Path.join(tmp, "test/fixtures/stub/recorded/leak.json"))
    end

    test "stores size and digest instead of a body that is not UTF-8", %{tmp: tmp} do
      bytes = <<0xFF, 0xD8, 0xFF, 0x00>>
      base_url = start_stub([{200, {:raw, "image/jpeg", bytes}}])

      with_env(%{"JIDO_CONNECT_RECORD" => "1"}, fn ->
        put_req_options(retry: false)
        :ok = LiveSmoke.record({:jido_connect, @req_key}, :stub, "download", root: tmp)
        assert {:ok, %Req.Response{status: 200, body: ^bytes}} = get(base_url, "/v1/file")
      end)

      envelope =
        Path.join(tmp, "test/fixtures/stub/recorded/download.json")
        |> File.read!()
        |> Jason.decode!()

      assert envelope["body"] == nil
      assert envelope["body_bytes"] == 4
      assert envelope["body_sha256"] == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    end

    test "leaves the Req options alone unless JIDO_CONNECT_RECORD=1", %{tmp: tmp} do
      with_env(%{"JIDO_CONNECT_RECORD" => nil}, fn ->
        put_req_options(retry: false)
        assert :ok = LiveSmoke.record({:jido_connect, @req_key}, :stub, "off", root: tmp)
        assert Application.get_env(:jido_connect, @req_key) == [retry: false]
        refute LiveSmoke.recording?()
      end)
    end

    test "refuses to record while a plug replaces the network", %{tmp: tmp} do
      with_env(%{"JIDO_CONNECT_RECORD" => "1"}, fn ->
        put_req_options(plug: {Req.Test, __MODULE__})

        assert_raise ArgumentError, ~r/:plug/, fn ->
          LiveSmoke.record({:jido_connect, @req_key}, :stub, "plugged", root: tmp)
        end
      end)
    end
  end

  describe "captures" do
    test "sanitizing re-signs a Slack capture for the replay secret" do
      raw = slack_capture(~s({"event":{"type":"message","user_email":"ada@corp.test"}}), "secret")

      sanitized = LiveSmoke.sanitize_capture(raw, secret: "secret")

      assert sanitized["body"] =~ "person-1@example.com"
      refute sanitized["body"] =~ "ada@corp.test"
      refute Map.has_key?(sanitized["headers"], "x-forwarded-for")
      assert sanitized["headers"]["x-slack-request-timestamp"] == "1700000000"

      assert sanitized["headers"]["x-slack-signature"] ==
               slack_signature(LiveSmoke.replay_secret(), "1700000000", sanitized["body"])

      assert sanitized["captured_at"] == raw["captured_at"]
    end

    test "sanitizing refuses a capture whose original signature does not verify" do
      raw = slack_capture(~s({"type":"event_callback"}), "secret")
      tampered = Map.put(raw, "body", ~s({"type":"event_callback","forged":true}))

      assert_raise ArgumentError, ~r/secret/, fn -> LiveSmoke.sanitize_capture(raw) end

      assert_raise ArgumentError, ~r/does not verify/, fn ->
        LiveSmoke.sanitize_capture(tampered, secret: "secret")
      end

      assert_raise ArgumentError, ~r/does not verify/, fn ->
        LiveSmoke.sanitize_capture(raw, secret: "other-secret")
      end
    end

    test "replay passes the capture to verify_delivery/4 with the captured time as now", %{
      tmp: tmp
    } do
      capture = slack_capture(~s({"type":"event_callback"}), "secret")

      path =
        LiveSmoke.write_capture!(capture, :slack, "event_callback", root: tmp, secret: "secret")

      assert path == Path.join(tmp, "test/fixtures/slack/captured/event_callback.json")
      assert {:ok, :verified} = LiveSmoke.replay(path, webhook: RecordingWebhook)

      assert_received {:verify_delivery, body, headers, secret, opts}
      assert body == ~s({"type":"event_callback"})
      assert headers["x-slack-request-timestamp"] == "1700000000"
      assert secret == LiveSmoke.replay_secret()
      assert opts[:now] == 1_700_000_003

      assert {:ok, :verified} =
               LiveSmoke.replay(capture,
                 webhook: RecordingWebhook,
                 secret: "secret",
                 seen_delivery_ids: ["Ev1"]
               )

      assert_received {:verify_delivery, _body, _headers, "secret", opts}
      assert opts[:seen_delivery_ids] == ["Ev1"]
    end
  end

  defp slack_capture(body, secret) do
    %{
      "provider" => "slack",
      "method" => "POST",
      "path" => "/integrations/slack/events",
      "captured_at" => 1_700_000_003,
      "headers" => %{
        "content-type" => "application/json",
        "x-forwarded-for" => "203.0.113.7",
        "x-slack-request-timestamp" => "1700000000",
        "x-slack-signature" => slack_signature(secret, "1700000000", body)
      },
      "body" => body
    }
  end

  defp slack_signature(secret, timestamp, body) do
    "v0=" <>
      (:hmac
       |> :crypto.mac(:sha256, secret, "v0:#{timestamp}:#{body}")
       |> Base.encode16(case: :lower))
  end

  defp get(base_url, path) do
    base_url
    |> Transport.bearer_request("stub-access-token",
      req_options: Application.get_env(:jido_connect, @req_key, [])
    )
    |> Req.get(url: path)
  end

  defp put_req_options(options) do
    Application.put_env(:jido_connect, @req_key, options)
    on_exit(fn -> Application.delete_env(:jido_connect, @req_key) end)
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

  defp start_stub(responses) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> serve(listen, responses) end)
    on_exit(fn -> :gen_tcp.close(listen) end)
    "http://127.0.0.1:#{port}"
  end

  defp serve(_listen, []), do: :ok

  defp serve(listen, [{status, body} | responses]) do
    {:ok, socket} = :gen_tcp.accept(listen)
    :ok = read_head(socket, "")

    {content_type, payload} =
      case body do
        {:raw, content_type, bytes} -> {content_type, bytes}
        body -> {"application/json", Jason.encode!(body)}
      end

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} OK\r\n",
        "content-type: #{content_type}\r\n",
        "set-cookie: sid=stub\r\n",
        "content-length: #{byte_size(payload)}\r\n",
        "connection: close\r\n\r\n",
        payload
      ])

    :gen_tcp.close(socket)
    serve(listen, responses)
  end

  defp read_head(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      :ok
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      read_head(socket, buffer <> data)
    end
  end
end
