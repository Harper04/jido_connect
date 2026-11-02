defmodule Jido.Connect.Slack.WebhookTest do
  use ExUnit.Case, async: true

  alias Jido.Connect.{Error, WebhookDelivery}
  alias Jido.Connect.Slack.Webhook
  alias Jido.Connect.TestSupport.LiveSmoke

  @captured_dir Path.expand("../../fixtures/slack/captured", __DIR__)

  test "verifies valid Slack signature" do
    body = ~s({"type":"event_callback"})
    timestamp = "1700000000"
    signature = slack_signature("secret", timestamp, body)

    assert :ok =
             Webhook.verify_signature(
               body,
               %{
                 "x-slack-signature" => signature,
                 "x-slack-request-timestamp" => timestamp
               },
               "secret",
               now: 1_700_000_000
             )
  end

  test "rejects signed Slack JSON that is not an object" do
    timestamp = "1700000000"

    for body <- ["42", "[1,2]"] do
      headers = %{
        "x-slack-signature" => slack_signature("secret", timestamp, body),
        "x-slack-request-timestamp" => timestamp
      }

      assert {:error, %Error.ProviderError{provider: :slack, reason: :invalid_payload}} =
               Webhook.verify_delivery(body, headers, "secret", now: 1_700_000_000)
    end
  end

  test "rejects missing secret, stale timestamp, and invalid signature" do
    body = "{}"
    headers = %{"x-slack-signature" => "v0=bad", "x-slack-request-timestamp" => "1700000000"}

    assert {:error, %Error.AuthError{reason: :missing_signing_secret}} =
             Webhook.verify_signature(body, headers, nil, now: 1_700_000_000)

    assert {:error, %Error.AuthError{reason: :stale_timestamp}} =
             Webhook.verify_signature(body, headers, "secret", now: 1_700_001_000)

    assert {:error, %Error.AuthError{reason: :invalid_signature}} =
             Webhook.verify_signature(body, headers, "secret", now: 1_700_000_000)

    assert {:error, %Error.AuthError{reason: :missing_timestamp}} =
             Webhook.verify_signature(body, %{"x-slack-signature" => "v0=bad"}, "secret",
               now: 1_700_000_000
             )

    assert {:error, %Error.AuthError{reason: :invalid_timestamp}} =
             Webhook.verify_signature(
               body,
               %{"x-slack-signature" => "v0=bad", "x-slack-request-timestamp" => "nope"},
               "secret",
               now: 1_700_000_000
             )
  end

  test "returns url verification challenge" do
    assert {:ok, "challenge"} =
             Webhook.url_verification_challenge(%{
               "type" => "url_verification",
               "challenge" => "challenge"
             })

    assert {:error, %Error.ProviderError{provider: :slack, reason: :not_url_verification}} =
             Webhook.url_verification_challenge(%{"type" => "event_callback"})
  end

  describe "captured deliveries" do
    # Captured from the Slack test workspace and sanitized by the message
    # ingress live smoke test; see test/fixtures/slack/captured. Each long
    # text is a label followed by the capture checklist's test text.

    test "verify with their signature at the capture time and keep the normalized signal" do
      capture = capture!("app_mention")

      assert {:ok, %{"type" => "event_callback", "event_id" => "Ev0CE6SUA42V"}} =
               Webhook.verify_request(
                 capture["body"],
                 capture["headers"],
                 LiveSmoke.replay_secret(),
                 now: capture["captured_at"]
               )

      assert {:ok,
              %WebhookDelivery{
                provider: :slack,
                delivery_id: "Ev0CE6SUA42V",
                event: "app_mention",
                signature_state: :verified,
                duplicate?: true,
                metadata: %{team_id: "T0CEE692400"},
                payload: %{"type" => "event_callback"},
                normalized_signal: %{
                  event_id: "Ev0CE6SUA42V",
                  delivery: %{
                    provider: :slack,
                    event: "app_mention",
                    id: "Ev0CE6SUA42V",
                    duplicate?: true,
                    received_at: %DateTime{}
                  }
                }
              }} =
               LiveSmoke.replay(capture,
                 webhook: Webhook,
                 seen_delivery_ids: ["Ev0CE6SUA42V"]
               )
    end

    test "fail verification after a body change, with a wrong or missing secret, or when stale" do
      %{"body" => body, "headers" => headers, "captured_at" => now} = capture!("message_public")
      secret = LiveSmoke.replay_secret()
      timestamp = String.to_integer(headers["x-slack-request-timestamp"])

      # Derived: the captured body with another author, and with one more
      # byte, each under the captured signature.
      other_author =
        body |> Jason.decode!() |> put_in(["event", "user"], "U0CDEL6734M") |> Jason.encode!()

      for changed <- [other_author, body <> "\n"] do
        assert {:error, %Error.AuthError{reason: :invalid_signature}} =
                 Webhook.verify_delivery(changed, headers, secret, now: now)
      end

      assert {:error, %Error.AuthError{reason: :invalid_signature}} =
               Webhook.verify_delivery(body, headers, "another-signing-secret", now: now)

      for missing <- [nil, ""] do
        assert {:error, %Error.AuthError{reason: :missing_signing_secret}} =
                 Webhook.verify_delivery(body, headers, missing, now: now)
      end

      for stale <- [timestamp + 301, timestamp - 301] do
        assert {:error, %Error.AuthError{reason: :stale_timestamp}} =
                 Webhook.verify_delivery(body, headers, secret, now: stale)
      end

      assert {:ok, %WebhookDelivery{}} =
               Webhook.verify_delivery(body, headers, secret, now: timestamp + 300)
    end

    test "a signed URL challenge verifies without a message signal" do
      capture = capture!("message_public")
      timestamp = capture["headers"]["x-slack-request-timestamp"]

      # Derived: Slack's url_verification body with the capture's redacted
      # token, signed with the replay secret at the capture's timestamp.
      body =
        Jason.encode!(%{
          "token" => payload!("message_public")["token"],
          "challenge" => "jc-capture-challenge",
          "type" => "url_verification"
        })

      headers = %{
        "x-slack-request-timestamp" => timestamp,
        "x-slack-signature" => slack_signature(LiveSmoke.replay_secret(), timestamp, body)
      }

      assert {:ok,
              %WebhookDelivery{
                event: "url_verification",
                signature_state: :verified,
                normalized_signal: nil,
                payload: payload
              }} =
               Webhook.verify_delivery(body, headers, LiveSmoke.replay_secret(),
                 now: capture["captured_at"]
               )

      assert {:ok, "jc-capture-challenge"} = Webhook.url_verification_challenge(payload)

      assert {:error, %Error.ProviderError{reason: :unsupported_event}} =
               Webhook.normalize_event(payload)
    end

    test "plain messages keep full text and IDs, and no subtype, in each conversation class" do
      rows = [
        {"message_public", "message.channels", "plain-public", 705,
         %{
           event_id: "Ev0CDPELPFHV",
           channel: "C0CEEB41FU0",
           channel_type: "channel",
           ts: "1793627736.679599"
         }},
        {"message_private", "message.groups", "plain-private", 706,
         %{
           event_id: "Ev0CE2STPNRL",
           channel: "C0CD4JEJ9V5",
           channel_type: "group",
           ts: "1793627741.845469"
         }},
        {"message_im", "message.im", "dm", 695,
         %{
           event_id: "Ev0CE4LFTAAE",
           channel: "D0CD4G48UFR",
           channel_type: "im",
           ts: "1793627769.877489",
           sender: %{id: "U0CDPFT1RDJ"},
           conversation: %{id: "D0CD4G48UFR", type: "im"}
         }},
        {"message_mpim", "message.mpim", "group-dm", 701,
         %{
           event_id: "Ev0CE2SYTX70",
           channel: "C0CDELYPYKF",
           channel_type: "mpim",
           ts: "1793627778.999479",
           sender: %{id: "U0CDPFT1RDJ"},
           conversation: %{id: "C0CDELYPYKF", type: "mpim"}
         }}
      ]

      for {name, event, label, text_bytes, ids} <- rows do
        assert {:ok, %WebhookDelivery{event: "message", normalized_signal: delivered}} =
                 replay(name)

        signal = Map.delete(delivered, :delivery)
        assert {:ok, ^signal} = Webhook.normalize_signal(event, payload!(name))
        assert {:ok, ^signal} = Webhook.normalize_event(payload!(name))

        assert_capture_text(signal.text, label, text_bytes)

        assert signal ==
                 Map.merge(
                   %{
                     team_id: "T0CEE692400",
                     user: "U0CDPFT1RDJ",
                     text: signal.text,
                     event_ts: ids.ts
                   },
                   ids
                 ),
               name
      end
    end

    test "each conversation class trigger rejects messages of another class" do
      rows = [
        {"message_public", "message.groups", "channel"},
        {"message_private", "message.channels", "group"},
        {"message_im", "message.mpim", "im"},
        {"message_mpim", "message.im", "mpim"}
      ]

      for {name, event, channel_type} <- rows do
        assert {:error,
                %Error.ProviderError{
                  reason: :unsupported_channel_type,
                  details: %{channel_type: ^channel_type}
                }} = Webhook.normalize_signal(event, payload!(name))
      end
    end

    test "DM senders keep only the team IDs Slack sends for them" do
      # The captured DM carries `team`, but neither `user_team` nor
      # `source_team`, so the sender has no team ID.
      assert {:ok, signal} = Webhook.normalize_signal("message.im", payload!("message_im"))
      assert signal.sender == %{id: "U0CDPFT1RDJ"}
      refute Map.has_key?(signal, :user_team)
      refute Map.has_key?(signal, :source_team)

      # Derived: the captured DM with the `user_team` and `source_team` that
      # Slack adds for a person from another workspace, and with
      # `source_team` alone.
      both =
        payload!("message_im")
        |> put_in(["event", "user_team"], "T0OTHERTEAM")
        |> put_in(["event", "source_team"], "T0SOURCETEAM")

      assert {:ok,
              %{
                user_team: "T0OTHERTEAM",
                source_team: "T0SOURCETEAM",
                sender: %{id: "U0CDPFT1RDJ", team_id: "T0OTHERTEAM"}
              }} = Webhook.normalize_signal("message.im", both)

      source_only = put_in(payload!("message_im"), ["event", "source_team"], "T0SOURCETEAM")

      assert {:ok, %{sender: %{id: "U0CDPFT1RDJ", team_id: "T0SOURCETEAM"}}} =
               Webhook.normalize_signal("message.im", source_only)
    end

    test "a reply normalizes as a thread reply, a parent or an unthreaded message does not" do
      payload = payload!("message_thread_reply")

      assert {:ok,
              %{
                event_id: "Ev0CDYKF1AFM",
                channel: "C0CEEB41FU0",
                user: "U0CDPFT1RDJ",
                ts: "1793627837.279779",
                thread_ts: "1793627736.679599",
                text: text
              } = signal} = Webhook.normalize_signal("message.thread_reply", payload)

      assert_capture_text(text, "thread-reply", 705)
      refute Map.has_key?(signal, :subtype)
      assert {:ok, ^signal} = Webhook.normalize_signal("message.channels", payload)

      assert {:error, %Error.ProviderError{reason: :not_thread_reply}} =
               Webhook.normalize_signal("message.thread_reply", payload!("message_public"))

      # Derived: the captured reply with its thread's ts as its own, the shape
      # of a thread parent.
      parent = put_in(payload, ["event", "ts"], "1793627736.679599")

      assert {:error, %Error.ProviderError{reason: :thread_root_message}} =
               Webhook.normalize_signal("message.thread_reply", parent)
    end

    test "a file share yields subtype file_share and the IDs of its files" do
      payload = payload!("message_file_share")

      assert {:ok, %WebhookDelivery{event: "message", normalized_signal: delivered}} =
               replay("message_file_share")

      signal = Map.delete(delivered, :delivery)

      assert signal == %{
               team_id: "T0CEE692400",
               event_id: "Ev0CE4MN8W9G",
               channel: "C0CEEB41FU0",
               channel_type: "channel",
               user: "U0CDPFT1RDJ",
               text: "file-share",
               ts: "1793628005.878859",
               event_ts: "1793628005.878859",
               subtype: "file_share",
               file_ids: ["F0CE8HZ718U"]
             }

      assert {:ok, ^signal} = Webhook.normalize_signal("message.channels", payload)

      assert {:error, %Error.ProviderError{reason: :not_thread_reply}} =
               Webhook.normalize_signal("message.thread_reply", payload)

      # Derived: the captured file share without its `files` list.
      without_files = update_in(payload, ["event"], &Map.delete(&1, "files"))

      assert {:ok, Map.delete(signal, :file_ids)} ==
               Webhook.normalize_signal("message.channels", without_files)
    end

    test "a broadcast reply normalizes as channel message and as thread reply" do
      payload = payload!("message_thread_broadcast")

      assert {:ok, %WebhookDelivery{event: "message", normalized_signal: delivered}} =
               replay("message_thread_broadcast")

      signal = Map.delete(delivered, :delivery)
      assert_capture_text(signal.text, "broadcast-reply", 708)

      assert signal == %{
               team_id: "T0CEE692400",
               event_id: "Ev0CDYKGNNBV",
               channel: "C0CEEB41FU0",
               channel_type: "channel",
               user: "U0CDPFT1RDJ",
               text: signal.text,
               ts: "1793627849.603099",
               thread_ts: "1793627736.679599",
               event_ts: "1793627849.603099",
               subtype: "thread_broadcast"
             }

      for event <- ["message.channels", "message.thread_reply"] do
        assert {:ok, ^signal} = Webhook.normalize_signal(event, payload)
      end
    end

    test "an app mention and a message with the same mention text stay distinct" do
      assert {:ok, %WebhookDelivery{event: "app_mention", normalized_signal: mention}} =
               replay("app_mention")

      assert Map.delete(mention, :delivery) == %{
               team_id: "T0CEE692400",
               event_id: "Ev0CE6SUA42V",
               channel: "C0CEEB41FU0",
               user: "U0CDPFT1RDJ",
               text: mention.text,
               ts: "1793628489.450879"
             }

      assert "<@U0CDHUEBVEJ> " <> text = mention.text
      assert_capture_text(text, "app-mention", 704)

      assert {:ok, %WebhookDelivery{event: "message", normalized_signal: message}} =
               replay("message_mention")

      assert %{
               event_id: "Ev0CE6SU1YEM",
               channel_type: "channel",
               ts: "1793628489.450879",
               text: "<@U0CDHUEBVEJ> " <> ^text
             } = message

      refute Map.has_key?(message, :subtype)

      assert {:error, %Error.ProviderError{reason: :unsupported_event}} =
               Webhook.normalize_signal("app_mention", payload!("message_mention"))

      for event <- ["message", "message.channels", "message.thread_reply"] do
        assert {:error, %Error.ProviderError{reason: :unsupported_event}} =
                 Webhook.normalize_signal(event, payload!("app_mention"))
      end

      # Derived: the captured app mention under an event type the package
      # does not normalize.
      unknown = put_in(payload!("app_mention"), ["event", "type"], "unknown_event")

      assert {:error, %Error.ProviderError{reason: :unsupported_event}} =
               Webhook.normalize_event(unknown)
    end

    test "edits, deletions, bot messages and unknown subtypes stay unsupported" do
      # Derived: the captured plain message as a classic `bot_message`, with a
      # `bot_id` instead of a `user`, and with a subtype Slack does not define.
      public = payload!("message_public")

      bot_message =
        update_in(public, ["event"], fn event ->
          event
          |> Map.delete("user")
          |> Map.merge(%{"subtype" => "bot_message", "bot_id" => "B0DERIVED01"})
        end)

      unknown = put_in(public, ["event", "subtype"], "jc_unknown_subtype")

      rows = [
        {"message_changed", payload!("message_changed")},
        {"message_deleted", payload!("message_deleted")},
        {"bot_message", bot_message},
        {"jc_unknown_subtype", unknown}
      ]

      for {subtype, payload} <- rows,
          event <- ["message", "message.channels", "message.thread_reply"] do
        assert {:error,
                %Error.ProviderError{
                  reason: :unsupported_message_subtype,
                  details: %{subtype: ^subtype}
                }} = Webhook.normalize_signal(event, payload),
               "#{subtype} under #{event}"
      end

      for {name, delivery_id} <- [
            {"message_changed", "Ev0CDZKJCP45"},
            {"message_deleted", "Ev0CE6TBSZU1"}
          ] do
        assert {:ok,
                %WebhookDelivery{
                  event: "message",
                  delivery_id: ^delivery_id,
                  signature_state: :verified,
                  normalized_signal: nil
                }} = replay(name)
      end
    end

    test "message triggers declare every field the captured deliveries yield" do
      rows = [
        {"slack.event.app_mention", "app_mention", ["app_mention"]},
        {"slack.event.message.channels", "message.channels",
         [
           "message_public",
           "message_mention",
           "message_thread_reply",
           "message_thread_broadcast",
           "message_file_share"
         ]},
        {"slack.event.message.groups", "message.groups", ["message_private"]},
        {"slack.event.message.im", "message.im", ["message_im"]},
        {"slack.event.message.mpim", "message.mpim", ["message_mpim"]},
        {"slack.event.message.thread_reply", "message.thread_reply",
         ["message_thread_reply", "message_thread_broadcast"]}
      ]

      for {trigger_id, event, names} <- rows, name <- names do
        assert {:ok, signal} = Webhook.normalize_signal(event, payload!(name))

        assert {:ok, ^signal} = Zoi.parse(trigger(trigger_id).signal_schema, signal),
               "#{trigger_id} #{name}"
      end
    end
  end

  test "normalizes reaction added events with item metadata and actor identity" do
    payload = %{
      "type" => "event_callback",
      "team_id" => "T123",
      "event_id" => "Ev904",
      "event" => %{
        "type" => "reaction_added",
        "user" => "U123",
        "reaction" => "thumbsup",
        "item_user" => "U456",
        "item" => %{
          "type" => "message",
          "channel" => "C123",
          "ts" => "1700000000.000700"
        },
        "event_ts" => "1700000000.000800"
      }
    }

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev904",
              user: "U123",
              reaction: "thumbsup",
              item_user: "U456",
              item: %{
                "type" => "message",
                "channel" => "C123",
                "ts" => "1700000000.000700"
              },
              item_type: "message",
              channel: "C123",
              ts: "1700000000.000700",
              event_ts: "1700000000.000800",
              actor: %{id: "U123", team_id: "T123"},
              item_owner: %{id: "U456", team_id: "T123"}
            }} = Webhook.normalize_signal("reaction_added", payload)

    assert {:ok, %{reaction: "thumbsup", item_type: "message"}} =
             Webhook.normalize_event(payload)

    file_payload =
      put_in(payload, ["event", "item"], %{
        "type" => "file_comment",
        "file" => "F123",
        "file_comment" => "Fc123"
      })

    assert {:ok,
            %{
              item_type: "file_comment",
              file: "F123",
              file_comment: "Fc123"
            }} = Webhook.normalize_signal("reaction_added", file_payload)
  end

  test "normalizes reaction removed events with item metadata and actor identity" do
    payload = %{
      "type" => "event_callback",
      "team_id" => "T123",
      "event_id" => "Ev905",
      "event" => %{
        "type" => "reaction_removed",
        "user" => "U123",
        "reaction" => "thumbsup",
        "item_user" => "U456",
        "item" => %{
          "type" => "message",
          "channel" => "C123",
          "ts" => "1700000000.000700"
        },
        "event_ts" => "1700000000.000900"
      }
    }

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev905",
              user: "U123",
              reaction: "thumbsup",
              item_user: "U456",
              item: %{
                "type" => "message",
                "channel" => "C123",
                "ts" => "1700000000.000700"
              },
              item_type: "message",
              channel: "C123",
              ts: "1700000000.000700",
              event_ts: "1700000000.000900",
              actor: %{id: "U123", team_id: "T123"},
              item_owner: %{id: "U456", team_id: "T123"}
            }} = Webhook.normalize_signal("reaction_removed", payload)

    assert {:ok, %{reaction: "thumbsup", item_type: "message"}} =
             Webhook.normalize_event(payload)
  end

  test "normalizes channel created events with channel metadata" do
    payload =
      channel_event_payload("channel_created", "Ev906", %{
        "channel" => %{
          "id" => "C123",
          "name" => "project",
          "created" => 1_700_000_000,
          "creator" => "U123"
        }
      })

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev906",
              channel_id: "C123",
              channel: %{
                "id" => "C123",
                "name" => "project",
                "created" => 1_700_000_000,
                "creator" => "U123"
              },
              actor: %{id: "U123", team_id: "T123"}
            }} = Webhook.normalize_signal("channel_created", payload)

    assert {:ok, %{channel_id: "C123"}} = Webhook.normalize_event(payload)
  end

  test "normalizes channel rename events with channel metadata" do
    payload =
      channel_event_payload("channel_rename", "Ev907", %{
        "channel" => %{"id" => "C123", "name" => "project-renamed", "created" => 1_700_000_000},
        "event_ts" => "1700000000.001000"
      })

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev907",
              channel_id: "C123",
              channel: %{"id" => "C123", "name" => "project-renamed", "created" => 1_700_000_000},
              event_ts: "1700000000.001000"
            }} = Webhook.normalize_signal("channel_rename", payload)
  end

  test "normalizes channel archive and unarchive events with actor metadata" do
    archive_payload =
      channel_event_payload("channel_archive", "Ev908", %{
        "channel" => "C123",
        "user" => "U123",
        "event_ts" => "1700000000.001100"
      })

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev908",
              channel_id: "C123",
              user: "U123",
              event_ts: "1700000000.001100",
              actor: %{id: "U123", team_id: "T123"}
            }} = Webhook.normalize_signal("channel_archive", archive_payload)

    assert {:ok, signal} = Webhook.normalize_event(archive_payload)
    refute Map.has_key?(signal, :channel)

    unarchive_payload =
      channel_event_payload("channel_unarchive", "Ev909", %{
        "channel" => "C123",
        "user" => "U456",
        "event_ts" => "1700000000.001200"
      })

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev909",
              channel_id: "C123",
              user: "U456",
              event_ts: "1700000000.001200",
              actor: %{id: "U456", team_id: "T123"}
            }} = Webhook.normalize_signal("channel_unarchive", unarchive_payload)
  end

  test "normalizes member joined channel events with membership metadata" do
    payload =
      channel_event_payload("member_joined_channel", "Ev910", %{
        "user" => "U123",
        "channel" => "C123",
        "channel_type" => "C",
        "team" => "T123",
        "inviter" => "U456",
        "event_ts" => "1700000000.001300"
      })

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev910",
              channel_id: "C123",
              channel: "C123",
              channel_type: "C",
              user: "U123",
              inviter: "U456",
              event_ts: "1700000000.001300",
              actor: %{id: "U123", team_id: "T123"},
              inviter_user: %{id: "U456", team_id: "T123"}
            }} = Webhook.normalize_signal("member_joined_channel", payload)

    assert {:ok, %{channel_id: "C123", user: "U123"}} = Webhook.normalize_event(payload)
  end

  test "normalizes member left channel events with membership metadata" do
    payload =
      channel_event_payload("member_left_channel", "Ev911", %{
        "user" => "U123",
        "channel" => "C123",
        "channel_type" => "C",
        "team" => "T123",
        "event_ts" => "1700000000.001400"
      })

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev911",
              channel_id: "C123",
              channel: "C123",
              channel_type: "C",
              user: "U123",
              event_ts: "1700000000.001400",
              actor: %{id: "U123", team_id: "T123"}
            }} = Webhook.normalize_signal("member_left_channel", payload)

    assert {:ok, signal} = Webhook.normalize_event(payload)
    refute Map.has_key?(signal, :inviter)
    refute Map.has_key?(signal, :inviter_user)
  end

  test "normalizes file created events with file metadata" do
    payload = file_event_payload("file_created", "Ev912", %{"user_id" => "U123"})

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev912",
              file_id: "F123",
              file: %{"id" => "F123"},
              user_id: "U123",
              actor: %{id: "U123", team_id: "T123"}
            }} = Webhook.normalize_signal("file_created", payload)

    assert {:ok, %{file_id: "F123"}} = Webhook.normalize_event(payload)
  end

  test "normalizes file shared events with channel and actor metadata" do
    payload =
      file_event_payload("file_shared", "Ev907", %{
        "channel_id" => "C123",
        "user_id" => "U123",
        "event_ts" => "1700000000.001000"
      })

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev907",
              file_id: "F123",
              file: %{"id" => "F123"},
              user_id: "U123",
              channel_id: "C123",
              event_ts: "1700000000.001000",
              actor: %{id: "U123", team_id: "T123"}
            }} = Webhook.normalize_signal("file_shared", payload)

    assert {:ok, %{channel_id: "C123"}} = Webhook.normalize_event(payload)
  end

  test "normalizes file public events" do
    payload = file_event_payload("file_public", "Ev908")

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev908",
              file_id: "F123",
              file: %{"id" => "F123"}
            }} = Webhook.normalize_signal("file_public", payload)
  end

  test "normalizes file deleted events without requiring embedded file metadata" do
    payload =
      file_event_payload("file_deleted", "Ev909", %{"event_ts" => "1700000000.001100"})
      |> update_in(["event"], &Map.delete(&1, "file"))

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev909",
              file_id: "F123",
              event_ts: "1700000000.001100"
            }} = Webhook.normalize_signal("file_deleted", payload)

    assert {:ok, signal} = Webhook.normalize_event(payload)
    refute Map.has_key?(signal, :file)
  end

  test "normalizes file change events" do
    payload =
      file_event_payload("file_change", "Ev910", %{
        "event_ts" => "1700000000.001200",
        "file" => %{"id" => "F123", "name" => "report.pdf"}
      })

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev910",
              file_id: "F123",
              file: %{"id" => "F123", "name" => "report.pdf"},
              event_ts: "1700000000.001200"
            }} = Webhook.normalize_signal("file_change", payload)
  end

  test "normalizes app uninstalled events" do
    payload =
      app_lifecycle_payload("app_uninstalled", "Ev916", %{}, %{
        "authorizations" => [
          %{
            "team_id" => "T123",
            "user_id" => "U123",
            "is_bot" => false,
            "is_enterprise_install" => false
          }
        ]
      })

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev916",
              api_app_id: "A123",
              event_time: 1_700_000_000,
              authorizations: [
                %{
                  "team_id" => "T123",
                  "user_id" => "U123",
                  "is_bot" => false,
                  "is_enterprise_install" => false
                }
              ]
            }} = Webhook.normalize_signal("app_uninstalled", payload)

    assert {:ok, %{api_app_id: "A123"}} = Webhook.normalize_event(payload)
  end

  test "normalizes tokens revoked events without exposing token material" do
    payload =
      app_lifecycle_payload("tokens_revoked", "Ev917", %{
        "tokens" => %{
          "oauth" => ["U123"],
          "bot" => ["U999"]
        }
      })

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev917",
              api_app_id: "A123",
              event_time: 1_700_000_000,
              tokens: %{"oauth" => ["U123"], "bot" => ["U999"]},
              oauth_user_ids: ["U123"],
              bot_user_ids: ["U999"]
            }} = Webhook.normalize_signal("tokens_revoked", payload)

    assert {:ok, %{oauth_user_ids: ["U123"], bot_user_ids: ["U999"]}} =
             Webhook.normalize_event(payload)
  end

  test "normalizes scope denied events conservatively" do
    payload =
      app_lifecycle_payload("scope_denied", "Ev918", %{
        "scopes" => ["channels:history"],
        "user" => "U123",
        "trigger_id" => "123.456",
        "event_ts" => "1700000000.001300"
      })

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev918",
              api_app_id: "A123",
              event_time: 1_700_000_000,
              scopes: ["channels:history"],
              user: "U123",
              trigger_id: "123.456",
              event_ts: "1700000000.001300"
            }} = Webhook.normalize_signal("scope_denied", payload)

    assert {:ok, %{scopes: ["channels:history"]}} = Webhook.normalize_event(payload)
  end

  test "normalizes app home opened events with view metadata" do
    payload =
      app_lifecycle_payload("app_home_opened", "Ev919", %{
        "user" => "U123",
        "channel" => "D123",
        "tab" => "home",
        "event_ts" => "1700000000.001400",
        "view" => %{
          "id" => "V123",
          "team_id" => "T123",
          "type" => "home",
          "app_id" => "A123"
        }
      })

    assert {:ok,
            %{
              team_id: "T123",
              event_id: "Ev919",
              api_app_id: "A123",
              user: "U123",
              channel: "D123",
              tab: "home",
              event_ts: "1700000000.001400",
              view: %{"id" => "V123", "team_id" => "T123", "type" => "home", "app_id" => "A123"},
              actor: %{id: "U123", team_id: "T123"},
              conversation: %{id: "D123", type: "app_home", tab: "home"}
            }} = Webhook.normalize_signal("app_home_opened", payload)

    assert {:ok, %{conversation: %{type: "app_home"}}} = Webhook.normalize_event(payload)
  end

  test "invalid JSON payloads are provider errors" do
    body = "not json"
    timestamp = "1700000000"
    signature = slack_signature("secret", timestamp, body)

    assert {:error, %Error.ProviderError{provider: :slack, reason: :invalid_payload}} =
             Webhook.verify_request(
               body,
               %{
                 "x-slack-signature" => signature,
                 "x-slack-request-timestamp" => timestamp
               },
               "secret",
               now: 1_700_000_000
             )
  end

  defp capture!(name),
    do: @captured_dir |> Path.join("#{name}.json") |> File.read!() |> Jason.decode!()

  defp payload!(name), do: name |> capture!() |> Map.fetch!("body") |> Jason.decode!()

  defp replay(name), do: name |> capture!() |> LiveSmoke.replay(webhook: Webhook)

  # The checklist text arrives whole: its label, its opening words and its
  # closing words, at the byte size of the captured text.
  defp assert_capture_text(text, label, bytes) do
    assert byte_size(text) == bytes
    assert String.starts_with?(text, label <> " Live capture for the Slack ingress tests")
    assert String.ends_with?(text, " End of capture text.")
  end

  defp trigger(id), do: Enum.find(Jido.Connect.Slack.integration().triggers, &(&1.id == id))

  defp slack_signature(secret, timestamp, body) do
    base = "v0:#{timestamp}:#{body}"

    signature =
      :hmac
      |> :crypto.mac(:sha256, secret, base)
      |> Base.encode16(case: :lower)

    "v0=#{signature}"
  end

  defp file_event_payload(type, event_id, event_attrs \\ %{}) do
    %{
      "type" => "event_callback",
      "team_id" => "T123",
      "event_id" => event_id,
      "event" =>
        Map.merge(
          %{
            "type" => type,
            "file_id" => "F123",
            "file" => %{"id" => "F123"}
          },
          event_attrs
        )
    }
  end

  defp channel_event_payload(type, event_id, event_attrs) do
    %{
      "type" => "event_callback",
      "team_id" => "T123",
      "event_id" => event_id,
      "event" => Map.put(event_attrs, "type", type)
    }
  end

  defp app_lifecycle_payload(type, event_id, event_attrs, payload_attrs \\ %{}) do
    Map.merge(
      %{
        "type" => "event_callback",
        "team_id" => "T123",
        "api_app_id" => "A123",
        "event_id" => event_id,
        "event_time" => 1_700_000_000,
        "event" => Map.put(event_attrs, "type", type)
      },
      payload_attrs
    )
  end
end
