defmodule Jido.Connect.Slack.ConversationHistoryLiveSmokeTest do
  @moduledoc """
  Live checks of Slack conversation history against the Slack test workspace.

      MIX_ENV=test mix do --app jido_connect_slack test --only live_smoke

  The recording tests read the public channel in two pages, an empty page and
  a channel the bot has left, and record the responses as fixtures. A single
  unpaged `conversations.history` call, made with Req outside the package,
  sets the page size.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect
  alias Jido.Connect.Slack.Client

  @slack_api "https://slack.com/api"
  @req_options {:jido_connect_slack, :slack_req_options}

  # File previews hold file content, and file links name the workspace or
  # carry a public link key; no offline test needs them.
  @file_fields ["preview", "preview_highlight", "permalink", "permalink_public", "edit_link"]

  @tag env!(["SLACK_BOT_TOKEN", "SLACK_PUBLIC_CHANNEL_ID", "SLACK_NO_ACCESS_CHANNEL_ID"])
  test "records a full and a short page, an empty page and a denied read", %{env: env} do
    token = env["SLACK_BOT_TOKEN"]
    channel = env["SLACK_PUBLIC_CHANNEL_ID"]
    reference = reference_history!(token, channel)
    limit = page_limit(reference)
    params = %{channel: channel, conversation_type: "public_channel", limit: limit}

    record("conversation_history_pages")

    assert {:ok, %{has_more: true, next_cursor: cursor} = full} =
             Client.get_conversation_history(params, token)

    assert length(full.messages) == limit
    assert cursor != ""

    assert {:ok, %{has_more: false} = short} =
             Client.get_conversation_history(Map.put(params, :cursor, cursor), token)

    assert length(short.messages) == length(reference) - limit

    record("conversation_history_empty")

    assert {:ok, %{messages: [], has_more: false}} =
             Client.get_conversation_history(Map.put(params, :latest, "1000000000.000000"), token)

    record("conversation_history_not_in_channel")

    assert {:error, %Connect.Error.ProviderError{reason: "not_in_channel"}} =
             Client.get_conversation_history(
               %{channel: env["SLACK_NO_ACCESS_CHANNEL_ID"], conversation_type: "public_channel"},
               token
             )
  end

  # The prepared messages carry no legacy attachments and no empty text, so
  # this test posts one such bot message, records the page and deletes it.
  @tag env!(["SLACK_BOT_TOKEN", "SLACK_PUBLIC_CHANNEL_ID"])
  @tag write!(:slack)
  test "records a bot message with attachments and empty text", %{env: env} do
    token = env["SLACK_BOT_TOKEN"]
    channel = env["SLACK_PUBLIC_CHANNEL_ID"]

    ts =
      post_reference!(token, %{
        channel: channel,
        text: "",
        attachments: [
          %{
            fallback: "Live smoke attachment",
            title: "Live smoke attachment",
            text: "Legacy attachment posted by the conversation history live test.",
            fields: [%{title: "Kind", value: "attachment", short: true}]
          }
        ]
      })

    on_exit(fn -> delete_reference(token, channel, ts) end)

    record("conversation_history_attachments")

    assert {:ok, %{messages: [message], has_more: false}} =
             Client.get_conversation_history(
               %{
                 channel: channel,
                 conversation_type: "public_channel",
                 oldest: ts,
                 latest: ts,
                 inclusive: true,
                 limit: 1
               },
               token
             )

    assert message.ts == ts
    assert message.text == ""
    assert [%{"fields" => [%{"title" => "Kind"}]}] = message.attachments
  end

  defp record(name), do: LiveSmoke.record(@req_options, :slack, name, fields: @file_fields)

  # Two pages: the first full, the second shorter. Needs three messages.
  defp page_limit(reference) do
    assert length(reference) >= 3
    div(length(reference), 2) + 1
  end

  defp reference_history!(token, channel) do
    %{status: 200, body: %{"ok" => true, "has_more" => false, "messages" => messages}} =
      reference_request(token, :get, "conversations.history",
        params: [channel: channel, limit: 100]
      )

    messages
  end

  defp post_reference!(token, payload) do
    %{status: 200, body: %{"ok" => true, "ts" => ts}} =
      reference_request(token, :post, "chat.postMessage", json: payload)

    ts
  end

  defp delete_reference(token, channel, ts) do
    reference_request(token, :post, "chat.delete", json: %{channel: channel, ts: ts})
  end

  # Calls Slack directly, without the package's client and Req options.
  defp reference_request(token, method, path, options) do
    [method: method, url: "#{@slack_api}/#{path}", auth: {:bearer, token}, retry: false]
    |> Keyword.merge(options)
    |> Req.request!()
  end
end
