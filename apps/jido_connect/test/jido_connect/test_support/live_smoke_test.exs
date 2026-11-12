defmodule Jido.Connect.TestSupport.LiveSmokeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Jido.Connect.Provider.Transport
  alias Jido.Connect.TestSupport.LiveSmoke
  alias Jido.Connect.TestSupport.LiveSmoke.{LeakError, Sanitize}

  require LiveSmoke

  @req_key :live_smoke_test_req_options
  @docs Path.expand("../../../../../docs/live_smoke_tests.md", __DIR__)

  setup do
    tmp = Path.join(System.tmp_dir!(), "live-smoke-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "env!/1" do
    test "skips with the names of unset variables" do
      with_env(%{"SLACK_BOT_TOKEN" => nil, "SLACK_PUBLIC_CHANNEL_ID" => ""}, fn ->
        tags = LiveSmoke.env!(["SLACK_BOT_TOKEN", "SLACK_PUBLIC_CHANNEL_ID"])

        assert tags[:live_env] == ["SLACK_BOT_TOKEN", "SLACK_PUBLIC_CHANNEL_ID"]
        assert tags[:skip] =~ "SLACK_BOT_TOKEN"
        assert tags[:skip] =~ "SLACK_PUBLIC_CHANNEL_ID"
      end)
    end

    test "leaves the test runnable when every variable is set" do
      with_env(%{"SLACK_BOT_TOKEN" => "xoxb-live-smoke-test"}, fn ->
        assert LiveSmoke.env!(["SLACK_BOT_TOKEN"]) == [live_env: ["SLACK_BOT_TOKEN"]]
      end)
    end

    test "prints the reason with the test location only when the run includes :live_smoke" do
      include = ExUnit.configuration()[:include]

      with_env(%{"SLACK_BOT_TOKEN" => nil}, fn ->
        assert capture_io(fn -> LiveSmoke.env!(["SLACK_BOT_TOKEN"]) end) == ""

        try do
          ExUnit.configure(include: [:live_smoke])
          output = capture_io(fn -> LiveSmoke.env!(["SLACK_BOT_TOKEN"]) end)

          assert output =~ "live_smoke skip test/jido_connect/test_support/live_smoke_test.exs:"
          assert output =~ "set SLACK_BOT_TOKEN to run this live test"
        after
          ExUnit.configure(include: include)
        end
      end)
    end

    test "rejects variables the convention does not list" do
      assert_raise ArgumentError, ~r/SLACK_BOT_TOKN/, fn -> LiveSmoke.env!(["SLACK_BOT_TOKN"]) end
    end

    test "setup passes the values to the test context" do
      with_env(%{"SLACK_PUBLIC_CHANNEL_ID" => "C0000000001"}, fn ->
        assert %{env: %{"SLACK_PUBLIC_CHANNEL_ID" => "C0000000001"}} =
                 LiveSmoke.setup_live_env(%{live_env: ["SLACK_PUBLIC_CHANNEL_ID"]})
      end)

      assert LiveSmoke.setup_live_env(%{}) == :ok

      with_env(%{"SLACK_PUBLIC_CHANNEL_ID" => ""}, fn ->
        assert_raise ArgumentError, ~r/SLACK_PUBLIC_CHANNEL_ID/, fn ->
          LiveSmoke.setup_live_env(%{live_env: ["SLACK_PUBLIC_CHANNEL_ID"]})
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
      with_env(%{"SLACK_LIVE_DESTRUCTIVE" => nil}, fn ->
        assert_raise ArgumentError, ~r/SLACK_LIVE_DESTRUCTIVE=true/, fn ->
          LiveSmoke.setup_live_env(%{live_write: :slack})
        end
      end)

      assert_raise ArgumentError, ~r/write!\/1/, fn ->
        LiveSmoke.setup_live_env(%{live_write: true})
      end
    end
  end

  describe "sanitize" do
    test "drops auth, cookie, signature, forwarding and CloudFront edge headers" do
      headers = %{
        "authorization" => ["Bearer secret"],
        "cookie" => ["sid=1"],
        "set-cookie" => ["sid=2"],
        "x-slack-signature" => ["v0=abc"],
        "x-forwarded-for" => ["203.0.113.7"],
        "X-Amz-Cf-Pop" => ["FRA56-P5"],
        "x-amz-cf-id" => ["abc"],
        "Content-Type" => ["application/json"]
      }

      fixture = %{"request" => %{"path" => "/"}, "headers" => headers, "body" => nil}

      assert LiveSmoke.sanitize_fixture(fixture)["headers"] == %{
               "x-amz-cf-id" => ["abc"],
               "content-type" => ["application/json"]
             }
    end

    test "redacts the keys that Jido.Connect.Sanitizer redacts, except keep_keys:" do
      body = %{
        "access_token" => "ya29.secret",
        "nested" => [%{"refresh_token" => "1//secret", "ok" => true}],
        "fields" => %{"summary" => "Broken build", "reporter" => "ada@corp.test"}
      }

      assert LiveSmoke.sanitize(body) == %{
               "access_token" => "[redacted]",
               "nested" => [%{"refresh_token" => "[redacted]", "ok" => true}],
               "fields" => %{"summary" => "Broken build", "reporter" => "person-1@example.com"}
             }

      assert LiveSmoke.sanitize(body, keep_keys: [])["fields"] == "[redacted]"
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

    test "replaces addresses and names in the map keys of fields: values" do
      body = %{
        "calendars" => %{"ada@corp.test" => %{"busy" => []}},
        "owner" => %{"displayName" => "Ada Lovelace"},
        "notes" => %{"Ada Lovelace" => "on leave"}
      }

      assert LiveSmoke.sanitize(body, fields: ["calendars", "notes"]) == %{
               "calendars" => %{"person-1@example.com" => %{"busy" => []}},
               "owner" => %{"displayName" => "Person 1"},
               "notes" => %{"Person 1" => "notes-1"}
             }
    end

    test "keeps addresses and placeholders whole when a name is a word of them" do
      # Names are replaced in the text between addresses and placeholders, so
      # a name such as "Person" or "example.com" cannot change either.
      body = %{
        "users" => [
          %{"displayName" => "Person", "email" => "ada@corp.test"},
          %{"displayName" => "example.com", "email" => "grace@corp.test"}
        ],
        "text" => "Person 3 wrote to ada@corp.test about example.com"
      }

      sanitized = LiveSmoke.sanitize(body)

      assert sanitized == %{
               "users" => [
                 %{"displayName" => "Person 1", "email" => "person-1@example.com"},
                 %{"displayName" => "Person 2", "email" => "person-2@example.com"}
               ],
               "text" => "Person 3 wrote to person-1@example.com about Person 2"
             }

      assert LiveSmoke.sanitize(sanitized) == sanitized

      # A `<field>-<n>` placeholder stays whole, also outside its field.
      fielded = %{"username" => "Text", "text" => "first", "reference" => "text-1"}

      assert LiveSmoke.sanitize(fielded, fields: ["text"]) == %{
               "username" => "Person 1",
               "text" => "text-2",
               "reference" => "text-1"
             }
    end

    test "replaces a name in any case, also where case folding differs" do
      # Upper case maps to the plain sigma, the name ends in the final one.
      body = %{"author" => %{"displayName" => "Σωκράτης"}, "note" => "ΣΩΚΡΆΤΗΣ wrote"}

      assert LiveSmoke.sanitize(body) == %{
               "author" => %{"displayName" => "Person 1"},
               "note" => "Person 1 wrote"
             }
    end

    test "replaces thousands of learned names" do
      # As in a recording of the member list of a larger account.
      members = for n <- 1..2_000, do: %{"real_name" => "Member #{n}", "id" => "U#{n}"}
      body = %{"members" => members, "text" => "Member 1999 thanked Member 7"}

      task = Task.async(fn -> LiveSmoke.sanitize(body) end)
      sanitized = Task.await(task, 10_000)

      refute inspect(sanitized, limit: :infinity) =~ "Member"
      assert sanitized["text"] =~ ~r/^Person \d+ thanked Person \d+$/
      assert LiveSmoke.sanitize(sanitized) == sanitized
    end

    test "learns no name longer than 200 bytes" do
      # A paragraph in front of an address is no display name, and one regex
      # over a very long name would not compile.
      for size <- [201, 200_000] do
        paragraph = String.duplicate("x", size)
        body = %{"to" => paragraph <> " <ada@corp.test>", "note" => paragraph}

        assert LiveSmoke.sanitize(body) == %{
                 "to" => paragraph <> " <person-1@example.com>",
                 "note" => paragraph
               }
      end
    end

    test "sanitizes long runs of spaces or address characters in linear time" do
      # Each shape made an address pattern backtrack once per position.
      long_address = String.duplicate("a", 16_000) <> "@corp.test, Bob <bob@corp.test>"

      for {text, expected} <- [
            {String.duplicate(" ", 20_000) <> "x <y", :same},
            {String.duplicate("a", 200_000) <> "@x y.zz", :same},
            {long_address, "person-1@example.com, Person 1 <person-2@example.com>"}
          ] do
        task = Task.async(fn -> LiveSmoke.sanitize(%{"note" => text}) end)
        expected = if expected == :same, do: text, else: expected
        assert Task.await(task, 2_000) == %{"note" => expected}
      end
    end

    test "takes more name keys from name_keys:" do
      body = %{"user" => %{"name" => "ada.lovelace"}, "text" => "ada.lovelace joined"}

      assert LiveSmoke.sanitize(body) == body

      assert LiveSmoke.sanitize(body, name_keys: ["name"]) == %{
               "user" => %{"name" => "Person 1"},
               "text" => "Person 1 joined"
             }
    end

    test "leaves an already sanitized value unchanged" do
      body = %{
        "author" => %{"displayName" => "Ada Lovelace", "email" => "ada@corp.test"},
        "note" => "Ada Lovelace wrote to grace@corp.test"
      }

      once = LiveSmoke.sanitize(body)
      assert LiveSmoke.sanitize(once) == once
    end

    test "keeps its own placeholders and gives new values numbers no placeholder holds" do
      # The second fixture of a recording continues the numbering of the
      # first, so its placeholders need not start at 1.
      body = %{
        "a" => %{"displayName" => "Person 2", "email" => "person-2@example.com"},
        "b" => %{"displayName" => "Person 1", "email" => "person-1@example.com"},
        "c" => %{"displayName" => "Grace Hopper", "email" => "grace@corp.test"}
      }

      assert LiveSmoke.sanitize(body) == %{
               body
               | "c" => %{"displayName" => "Person 3", "email" => "person-3@example.com"}
             }
    end

    test "keeps the <field>-<n> placeholders of fields: and numbers new values around them" do
      # The second page of a recording with `fields: ["text"]` continues the
      # numbering of the first.
      body = %{
        "items" => [
          %{"text" => "text-6"},
          %{"text" => "Quarterly numbers attached"},
          %{"text" => "text-7"},
          %{"text" => "Quarterly numbers attached"}
        ]
      }

      assert LiveSmoke.sanitize(body, fields: ["text"]) == %{
               "items" => [
                 %{"text" => "text-6"},
                 %{"text" => "text-1"},
                 %{"text" => "text-7"},
                 %{"text" => "text-1"}
               ]
             }

      sanitized = %{"items" => [%{"text" => "text-1"}, %{"text" => "Second page"}]}

      assert LiveSmoke.sanitize(sanitized, fields: ["text"]) == %{
               "items" => [%{"text" => "text-1"}, %{"text" => "text-2"}]
             }
    end

    test "fails when a credential variable's value appears, naming only the variable" do
      token = "xoxb-live/smoke+leak=check"

      # Percent escapes in either case, or only some of them, are found too.
      leaks = [
        token,
        URI.encode_www_form(token),
        "xoxb-live%2fsmoke%2bleak%3dcheck",
        "xoxb-live%2Fsmoke+leak%3Dcheck",
        Base.encode64(token)
      ]

      with_env(%{"SLACK_BOT_TOKEN" => token}, fn ->
        for leaked <- leaks do
          error =
            assert_raise LeakError, fn ->
              LiveSmoke.sanitize(%{"next" => "https://example.test/?t=#{leaked}"})
            end

          assert Exception.message(error) =~ "SLACK_BOT_TOKEN"
          refute Exception.message(error) =~ token
        end
      end)

      # A form body writes a space as `+`, next to escapes in either case.
      with_env(%{"SLACK_BOT_TOKEN" => "xoxb live/smoke"}, fn ->
        assert_raise LeakError, ~r/SLACK_BOT_TOKEN/, fn ->
          LiveSmoke.sanitize(%{"form" => "token=xoxb+live%2fsmoke"})
        end
      end)
    end

    test "fails when a configured email address survives encoded" do
      email = "tester@acme.test"

      with_env(%{"LIVE_SMOKE_TEST_EMAIL" => email}, fn ->
        error =
          assert_raise LeakError, fn -> LiveSmoke.sanitize(%{"blob" => Base.encode64(email)}) end

        assert Exception.message(error) =~ "LIVE_SMOKE_TEST_EMAIL"
        refute Exception.message(error) =~ email

        assert LiveSmoke.sanitize(%{"owner" => email}) == %{"owner" => "person-1@example.com"}
      end)
    end

    test "fails when a guarded value is Base64-encoded at any offset of a longer value" do
      # With `~~~` each value encodes with `+` or `/` at every offset, so the
      # standard and the URL-safe encodings of the value differ.
      email = "tester~~~@acme.test"
      token = "xoxb-live-smoke~~~offset-check"

      with_env(%{"LIVE_SMOKE_TEST_EMAIL" => email, "SLACK_BOT_TOKEN" => token}, fn ->
        for prefix <- ["e", "ev", "evt", "evt0"],
            encode <- [&Base.url_encode64(&1, padding: false), &Base.encode64/1] do
          assert_raise LeakError, ~r/LIVE_SMOKE_TEST_EMAIL/, fn ->
            LiveSmoke.sanitize(%{"state" => encode.("#{prefix} #{email}")})
          end

          assert_raise LeakError, ~r/SLACK_BOT_TOKEN/, fn ->
            LiveSmoke.sanitize(%{"state" => encode.("#{prefix}:#{token}:#{prefix}")})
          end
        end
      end)
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

    test "check_leaks!/2 finds guarded values in a value as it is, also under redacted keys" do
      # A synthetic fixture is written by hand; sanitizing it first would
      # redact the token and replace the address.
      token = "xoxb-live-smoke-synthetic-check"
      email = "tester@acme.test"

      with_env(%{"SLACK_BOT_TOKEN" => token, "LIVE_SMOKE_TEST_EMAIL" => email}, fn ->
        for {fixture, variable} <- [
              {%{"access_token" => token}, "SLACK_BOT_TOKEN"},
              {%{"email" => email}, "LIVE_SMOKE_TEST_EMAIL"}
            ] do
          assert_raise LeakError, ~r/#{variable}/, fn -> LiveSmoke.check_leaks!(fixture) end
        end

        clean = %{"access_token" => "stub-access-token", "email" => "person-1@example.com"}
        assert LiveSmoke.check_leaks!(clean) == :ok
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
      token = "xoxb-live-smoke-recorded-leak"
      base_url = start_stub([{200, %{"echo" => token}}])

      with_env(%{"JIDO_CONNECT_RECORD" => "1", "SLACK_BOT_TOKEN" => token}, fn ->
        put_req_options(retry: false)
        :ok = LiveSmoke.record({:jido_connect, @req_key}, :stub, "leak", root: tmp)

        error = assert_raise LeakError, fn -> get(base_url, "/v1/echo") end
        assert Exception.message(error) =~ "SLACK_BOT_TOKEN"
        refute Exception.message(error) =~ token
      end)

      refute File.exists?(Path.join(tmp, "test/fixtures/stub/recorded/leak.json"))
    end

    test "sanitize_fixture/2 leaves every file of a recording unchanged", %{tmp: tmp} do
      ada = %{"displayName" => "Ada Lovelace", "email" => "ada@corp.test"}
      grace = %{"displayName" => "Grace Hopper", "email" => "grace@corp.test"}

      base_url =
        start_stub([
          {200, %{"author" => ada, "note" => "Ada Lovelace opened it"}},
          {200, %{"author" => grace, "watchers" => [ada], "note" => "grace@corp.test asked Ada"}}
        ])

      with_env(%{"JIDO_CONNECT_RECORD" => "1"}, fn ->
        put_req_options(retry: false)
        :ok = LiveSmoke.record({:jido_connect, @req_key}, :stub, "people", root: tmp)
        assert {:ok, %Req.Response{status: 200}} = get(base_url, "/v1/issues/1")
        assert {:ok, %Req.Response{status: 200}} = get(base_url, "/v1/issues/2")
      end)

      for name <- ["people.json", "people.2.json"] do
        fixture =
          Path.join([tmp, "test/fixtures/stub/recorded", name]) |> File.read!() |> Jason.decode!()

        assert LiveSmoke.sanitize_fixture(fixture) == fixture
      end

      assert %{
               "author" => %{"displayName" => "Person 2", "email" => "person-2@example.com"},
               "watchers" => [%{"displayName" => "Person 1", "email" => "person-1@example.com"}]
             } = LiveSmoke.fixture!(:stub, "people.2", root: tmp)
    end

    test "numbers responses that finish at the same time without losing one", %{tmp: tmp} do
      base_url = start_stub([{200, %{"page" => "a"}}, {200, %{"page" => "b"}}])

      # The transform holds each response for a moment, so the second one
      # finishes while the first is still being written.
      transform = fn _path, body ->
        Process.sleep(100)
        body
      end

      with_env(%{"JIDO_CONNECT_RECORD" => "1"}, fn ->
        put_req_options(retry: false)

        :ok =
          LiveSmoke.record({:jido_connect, @req_key}, :stub, "parallel",
            root: tmp,
            transform: transform
          )

        ["/v1/a", "/v1/b"]
        |> Enum.map(fn path -> Task.async(fn -> get(base_url, path) end) end)
        |> Enum.each(&assert({:ok, %Req.Response{status: 200}} = Task.await(&1)))
      end)

      pages =
        for name <- ["parallel", "parallel.2"],
            do: LiveSmoke.fixture!(:stub, name, root: tmp)["page"]

      assert Enum.sort(pages) == ["a", "b"]
    end

    test "keeps JSON numbers and booleans as the body", %{tmp: tmp} do
      base_url = start_stub([{200, true}, {200, 42}])

      with_env(%{"JIDO_CONNECT_RECORD" => "1"}, fn ->
        put_req_options(retry: false)
        :ok = LiveSmoke.record({:jido_connect, @req_key}, :stub, "scalar", root: tmp)
        assert {:ok, %Req.Response{body: true}} = get(base_url, "/v1/flag")
        assert {:ok, %Req.Response{body: 42}} = get(base_url, "/v1/count")
      end)

      assert LiveSmoke.fixture!(:stub, "scalar", root: tmp) == true
      assert LiveSmoke.fixture!(:stub, "scalar.2", root: tmp) == 42
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

    test "a transform changes or skips what is recorded, not what the caller gets", %{tmp: tmp} do
      page = %{
        "results" => [%{"key" => "OWN-1"}, %{"key" => "OTHER-1", "name" => "Other site data"}],
        "metadata" => %{"count" => 2}
      }

      other = %{"key" => "OTHER-1", "name" => "Other site data"}
      own = %{"key" => "OWN-1"}
      base_url = start_stub([{200, page}, {200, other}, {200, own}])

      transform = fn
        "/v1/items/other 1", _body ->
          :skip

        _path, %{"results" => results} = body ->
          kept = Enum.filter(results, &(&1["key"] == "OWN-1"))
          %{body | "results" => kept, "metadata" => %{"count" => length(kept)}}

        _path, body ->
          body
      end

      with_env(%{"JIDO_CONNECT_RECORD" => "1"}, fn ->
        put_req_options(retry: false)

        :ok =
          LiveSmoke.record({:jido_connect, @req_key}, :stub, "items",
            root: tmp,
            transform: transform
          )

        assert {:ok, %Req.Response{body: ^page}} = get(base_url, "/v1/items")
        assert {:ok, %Req.Response{body: ^other}} = get(base_url, "/v1/items/other%201")
        assert {:ok, %Req.Response{body: ^own}} = get(base_url, "/v1/items/own-1")
      end)

      assert LiveSmoke.fixture!(:stub, "items", root: tmp) == %{
               "results" => [%{"key" => "OWN-1"}],
               "metadata" => %{"count" => 1}
             }

      # The skipped response takes no number, so the next one is items.2.
      assert LiveSmoke.fixture!(:stub, "items.2", root: tmp) == own

      dir = Path.join(tmp, "test/fixtures/stub/recorded")
      assert dir |> File.ls!() |> Enum.sort() == ["items.2.json", "items.json"]

      for file <- File.ls!(dir) do
        refute dir |> Path.join(file) |> File.read!() =~ "Other site data"
      end
    end

    test "marks a fixture whose body the transform changed", %{tmp: tmp} do
      base_url = start_stub([{200, %{"results" => [1, 2]}}, {200, %{"results" => [1]}}])

      transform = fn
        "/v1/changed", %{"results" => results} = body ->
          %{body | "results" => Enum.take(results, 1)}

        _path, body ->
          body
      end

      with_env(%{"JIDO_CONNECT_RECORD" => "1"}, fn ->
        put_req_options(retry: false)

        :ok =
          LiveSmoke.record({:jido_connect, @req_key}, :stub, "marked",
            root: tmp,
            transform: transform
          )

        assert {:ok, %Req.Response{body: %{"results" => [1, 2]}}} = get(base_url, "/v1/changed")
        assert {:ok, %Req.Response{body: %{"results" => [1]}}} = get(base_url, "/v1/same")
      end)

      dir = Path.join(tmp, "test/fixtures/stub/recorded")
      changed = dir |> Path.join("marked.json") |> File.read!() |> Jason.decode!()
      unchanged = dir |> Path.join("marked.2.json") |> File.read!() |> Jason.decode!()

      assert changed["transformed"] == true
      refute Map.has_key?(unchanged, "transformed")
      assert LiveSmoke.sanitize_fixture(changed) == changed
      assert LiveSmoke.fixture!(:stub, "marked", root: tmp) == %{"results" => [1]}
    end

    test "sanitizes and leak-checks the transformed body", %{tmp: tmp} do
      token = "xoxb-live-smoke-transform-leak"
      base_url = start_stub([{200, %{"ok" => true}}, {200, %{"ok" => true}}])

      with_env(%{"JIDO_CONNECT_RECORD" => "1", "SLACK_BOT_TOKEN" => token}, fn ->
        put_req_options(retry: false)

        :ok =
          LiveSmoke.record({:jido_connect, @req_key}, :stub, "owner",
            root: tmp,
            transform: fn _path, body -> Map.put(body, "owner", "ada@corp.test") end
          )

        assert {:ok, %Req.Response{body: %{"ok" => true}}} = get(base_url, "/v1/owner")

        :ok =
          LiveSmoke.record({:jido_connect, @req_key}, :stub, "leak",
            root: tmp,
            transform: fn _path, body -> Map.put(body, "echo", token) end
          )

        assert_raise LeakError, fn -> get(base_url, "/v1/echo") end
      end)

      assert LiveSmoke.fixture!(:stub, "owner", root: tmp) == %{
               "ok" => true,
               "owner" => "person-1@example.com"
             }

      refute File.exists?(Path.join(tmp, "test/fixtures/stub/recorded/leak.json"))
    end

    test "rejects a transform that is not a function of path and body", %{tmp: tmp} do
      with_env(%{"JIDO_CONNECT_RECORD" => "1"}, fn ->
        put_req_options(retry: false)

        assert_raise ArgumentError, ~r/:transform/, fn ->
          LiveSmoke.record({:jido_connect, @req_key}, :stub, "bad",
            root: tmp,
            transform: fn body -> body end
          )
        end
      end)
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

  # A one-shot HTTP server on a local port that answers each request with the
  # next response, so the recorder runs Finch against a real socket.
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
