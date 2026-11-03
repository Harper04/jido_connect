defmodule Jido.Connect.Slack.UserViewTest do
  use ExUnit.Case, async: true

  alias Jido.Connect.WebhookDelivery
  alias Jido.Connect.Slack.Webhook

  import Jido.Connect.Slack.TestSupport.CapturedDelivery,
    only: [payload!: 1, replay: 1, derive: 2]

  # The user-view captures came from the test workspace on 2026-11-02 and
  # were sanitized by the user view live smoke test: a message in
  # #jc-live-no-bot (C0CDDP1JEAX), which the bot has left, a mention of the
  # app in a public channel without the bot, and a message in a DM of the
  # authorizing user without the bot. Their texts are placeholders. The
  # other captures are the bot-view deliveries of the message ingress test.

  @bot_user "U0CDHUEBVEJ"
  @authorizing_user "U0CDPFT1RDJ"

  describe "message signals" do
    test "a captured user event from a channel the bot is not in normalizes through the public channel trigger" do
      payload = payload!("message_public_user_view")

      assert {:ok,
              %WebhookDelivery{
                signature_state: :verified,
                event: "message",
                normalized_signal: delivered
              }} = replay("message_public_user_view")

      signal = Map.delete(delivered, :delivery)

      assert signal == %{
               team_id: "T0CEE692400",
               event_id: "Ev0CEZC2RHB2",
               channel: "C0CDDP1JEAX",
               channel_type: "channel",
               user: @authorizing_user,
               text: payload["event"]["text"],
               ts: "1793628631.312089",
               event_ts: "1793628631.312089",
               view: "user",
               viewer: @authorizing_user
             }

      assert {:ok, ^signal} = Webhook.normalize_signal("message.channels", payload)
      assert {:ok, ^signal} = Webhook.normalize_event(payload)
    end

    test "a mention of the app in a channel without the bot is a user-view message" do
      payload = payload!("message_mention_user_view")

      # The bot user that the app_mention capture names as its authorization.
      assert [%{"is_bot" => true, "user_id" => @bot_user}] =
               payload!("app_mention")["authorizations"]

      assert [
               %{
                 "elements" => [
                   %{"elements" => [%{"type" => "user", "user_id" => @bot_user} | _]}
                 ]
               }
             ] =
               payload["event"]["blocks"]

      assert {:ok, signal} = Webhook.normalize_signal("message.channels", payload)

      assert %{channel: "C0CEE6E6EU8", ts: "1793627810.026799", view: "user"} = signal
      assert signal.viewer == @authorizing_user
    end

    test "a DM without the bot arrives in the user view with sender and conversation" do
      assert {:ok, %WebhookDelivery{normalized_signal: delivered}} =
               replay("message_im_user_view")

      signal = Map.delete(delivered, :delivery)
      payload = payload!("message_im_user_view")
      assert {:ok, ^signal} = Webhook.normalize_signal("message.im", payload)

      assert %{
               channel: "D0CDPKW29DJ",
               channel_type: "im",
               user: @authorizing_user,
               sender: %{id: @authorizing_user},
               conversation: %{id: "D0CDPKW29DJ", type: "im"},
               view: "user",
               viewer: @authorizing_user
             } = signal

      refute Map.has_key?(signal, :shared_messages)
    end

    test "captured deliveries from conversations with the bot name the bot's view" do
      for {fixture, trigger} <- [
            {"message_public", "message.channels"},
            {"message_private", "message.groups"},
            {"message_im", "message.im"},
            {"message_mpim", "message.mpim"},
            {"message_thread_reply", "message.thread_reply"},
            {"message_file_share", "message.channels"}
          ] do
        assert {:ok, %{view: "bot", viewer: @bot_user}} =
                 Webhook.normalize_signal(trigger, payload!(fixture)),
               fixture
      end
    end

    # Derived: the captured share into the bot DM, moved into the user's DM
    # without the bot with that DM's captured authorization. No share in such
    # a DM was captured.
    test "a share keeps shared_messages in both views; only the bot view is a handover" do
      user_view = payload!("message_im_user_view")

      assert {:ok, %WebhookDelivery{normalized_signal: handover}} =
               replay("message_im_shared_public")

      assert %{view: "bot", viewer: @bot_user, shared_messages: [shared]} = handover

      capture =
        derive("message_im_shared_public", fn payload ->
          payload
          |> Map.put("authorizations", user_view["authorizations"])
          |> put_in(["event", "channel"], "D0CDPKW29DJ")
        end)

      assert {:ok, %WebhookDelivery{normalized_signal: share}} = replay(capture)

      assert %{
               channel: "D0CDPKW29DJ",
               view: "user",
               viewer: @authorizing_user,
               shared_messages: [^shared]
             } = share
    end

    # Derived from the captured user event.
    test "a delivery without a readable authorization has no view" do
      payload = payload!("message_public_user_view")
      [authorization] = payload["authorizations"]

      for authorizations <- [
            nil,
            [],
            "not a list",
            ["not a map"],
            [Map.delete(authorization, "is_bot")],
            [Map.put(authorization, "is_bot", "false")]
          ] do
        assert {:ok, signal} =
                 payload
                 |> Map.put("authorizations", authorizations)
                 |> then(&Webhook.normalize_signal("message.channels", &1))

        refute Map.has_key?(signal, :view)
        refute Map.has_key?(signal, :viewer)
      end

      for user_id <- [nil, ""] do
        assert {:ok, signal} =
                 Webhook.normalize_signal(
                   "message.channels",
                   Map.put(payload, "authorizations", [
                     Map.put(authorization, "user_id", user_id)
                   ])
                 )

        assert signal.view == "user"
        refute Map.has_key?(signal, :viewer)
      end
    end
  end

  describe "change signals" do
    test "captured edits and deletions from conversations with the bot name the bot's view" do
      for {fixture, trigger} <- [
            {"message_changed_public", "message.channels.changed"},
            {"message_changed_im", "message.im.changed"},
            {"message_deleted_mpim", "message.mpim.deleted"},
            {"message_changed_tombstone", "message.channels.deleted"}
          ] do
        assert {:ok, %{view: "bot", viewer: @bot_user}} =
                 Webhook.normalize_signal(trigger, payload!(fixture)),
               fixture
      end
    end

    # The captured link unfurl in the user's DM without the bot is no edit.
    # Derived from it: the same change with a new message.edited.
    test "a change in a DM without the bot carries the user view" do
      assert {:ok, %WebhookDelivery{normalized_signal: nil}} = replay("message_changed_unfurl")

      capture =
        derive("message_changed_unfurl", fn payload ->
          put_in(payload, ["event", "message", "edited"], %{
            "user" => @authorizing_user,
            "ts" => "1793628140.000000"
          })
        end)

      assert {:ok, %WebhookDelivery{normalized_signal: %{} = signal}} = replay(capture)

      assert %{
               subtype: "message_changed",
               channel: "D0CDPKW29DJ",
               ts: "1793628131.336459",
               editor: @authorizing_user,
               view: "user",
               viewer: @authorizing_user
             } = signal
    end
  end
end
