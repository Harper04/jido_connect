defmodule Jido.Connect.Confluence.PageSourceTest do
  use ExUnit.Case, async: false

  # `confluence.page.get` on the page responses that the live tests recorded
  # from the test site (`test/fixtures/confluence/recorded/`): the tenant-bound
  # source URL and the errors of the page read.

  alias Jido.Connect
  alias Jido.Connect.Confluence
  alias Jido.Connect.Confluence.{Client, TestRuntime}
  alias Jido.Connect.Error
  alias Jido.Connect.TestSupport.LiveSmoke

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous = Application.get_env(:jido_connect_confluence, :confluence_req_options)

    Application.put_env(
      :jido_connect_confluence,
      :confluence_req_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:jido_connect_confluence, :confluence_req_options, previous)
      else
        Application.delete_env(:jido_connect_confluence, :confluence_req_options)
      end
    end)
  end

  @plain_url "https://example.atlassian.net/wiki/spaces/JCL/pages/3754688664/JCL+plain+page"

  test "client and generated action return the tenant URL of the page without a list request" do
    body = LiveSmoke.fixture!(:confluence, "plain_page_adf")

    expected = %{
      kind: "confluence_page",
      account: "confluence-account-1",
      id: "3754688664",
      title: "JCL plain page",
      revision_id: "1",
      version: 1,
      space_id: "3754655746",
      url: @plain_url,
      text: plain_text(),
      character_count: String.length(plain_text()),
      truncated: false
    }

    expect_page_read(body)
    assert Client.get_page(%{id: "3754688664"}, request()) == {:ok, expected}

    expect_page_read(body)
    assert invoke(%{id: "3754688664"}) == {:ok, expected}
  end

  test "an unusable webui link or a foreign base fails the read and names no other host" do
    # The test site returns only valid links, so each case changes one part of
    # the recorded `_links`.
    page = "/spaces/JCL/pages/3754688664/JCL+plain+page"

    changes = [
      &Map.delete(&1, "webui"),
      &Map.put(&1, "webui", "https://attacker.example/wiki" <> page),
      &Map.put(&1, "webui", "//attacker.example/wiki" <> page),
      &Map.put(&1, "webui", page <> "?next=https://attacker.example/wiki"),
      &Map.put(&1, "base", "https://attacker.example/wiki")
    ]

    for change <- changes do
      body = :confluence |> LiveSmoke.fixture!("plain_page_adf") |> Map.update!("_links", change)
      expect_page_read(body)

      assert {:error,
              %Error.ProviderError{
                provider: :confluence,
                reason: :invalid_response,
                delivery: :response_received,
                mutation?: false
              } = error} = Client.get_page(%{id: "3754688664"}, request())

      refute rendered(error) =~ "attacker.example"
    end
  end

  test "an unknown on_unsupported value fails before any request" do
    # No request is expected: a request would find no Req.Test stub.
    for value <- ["skip", "Degrade", "", :degrade, true] do
      assert {:error,
              %Error.ValidationError{
                reason: :invalid_confluence_input,
                subject: :on_unsupported
              }} = Client.get_page(%{id: "3754688664", on_unsupported: value}, request())

      assert {:error, %Error.ValidationError{}} =
               invoke(%{id: "3754688664", on_unsupported: value})
    end
  end

  defp expect_page_read(body) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/wiki/api/v2/pages/#{body["id"]}"
      assert URI.decode_query(conn.query_string) == %{"body-format" => "atlas_doc_format"}
      Req.Test.json(conn, body)
    end)
  end

  defp runtime, do: TestRuntime.build(provider_client: Client, api_token: "page-source-token")

  defp request do
    assert {:ok, request} = Client.request_context(runtime())
    request
  end

  defp invoke(input),
    do:
      Connect.invoke(Confluence, "confluence.page.get", input, TestRuntime.invoke_opts(runtime()))

  defp rendered(error), do: inspect(error) <> inspect(Error.to_map(error))

  # The text of the recorded plain page in the shared projection.
  defp plain_text do
    long_lines =
      for n <- 1..12 do
        number = n |> Integer.to_string() |> String.pad_leading(2, "0")

        "Line #{number} of the long live-test text for the plain page: " <>
          "Umlaute äöü ß, Euro €, Dash –."
      end

    Enum.join(
      [
        "Plain live-test page",
        "This page holds only content the ADF projection supports: headings, " <>
          "paragraphs, bold, italic, code and a link (https://example.com/jcl).",
        "- First list item",
        "- Second list item with Umlaute äöü",
        "1. Step one",
        "2. Step two"
        | long_lines
      ],
      "\n"
    )
  end
end
