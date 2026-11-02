defmodule Jido.Connect.Slack.Webhook.MessageChanges do
  @moduledoc false

  # Turns a `message` event with the subtype `message_changed` or
  # `message_deleted` into a change signal: the fields of
  # `Jido.Connect.Slack.MessageChange` that are not nil. The signal's `ts` is
  # the edited or deleted message's `ts`, never the notification's.
  #
  # Every value is read at a fixed payload path. A missing or empty
  # identity, a value that is no string, or a step on a path that is no map
  # fails with `:invalid_message_change`; a `previous_message.ts` that names
  # another message fails with `:conflicting_message_change`. The details
  # name payload paths and never a value, so no message text leaves through
  # an error.

  alias Jido.Connect.{Data, Error}
  alias Jido.Connect.Slack.MessageChange

  @channel_types [nil, "channel", "group", "im", "mpim"]

  # The event of each change trigger, with the subtype and the channel types
  # it accepts. Like `message.channels`, the public channel family also
  # takes an event without `channel_type`.
  @trigger_events %{
    "message.channels.changed" => {"message_changed", [nil, "channel"]},
    "message.channels.deleted" => {"message_deleted", [nil, "channel"]},
    "message.groups.changed" => {"message_changed", ["group"]},
    "message.groups.deleted" => {"message_deleted", ["group"]},
    "message.im.changed" => {"message_changed", ["im"]},
    "message.im.deleted" => {"message_deleted", ["im"]},
    "message.mpim.changed" => {"message_changed", ["mpim"]},
    "message.mpim.deleted" => {"message_deleted", ["mpim"]}
  }

  @identity_fields [
    team_id: ["team_id"],
    event_id: ["event_id"],
    channel: ["event", "channel"],
    channel_type: ["event", "channel_type"],
    subtype: ["event", "subtype"],
    notification_ts: ["event", "ts"],
    event_ts: ["event", "event_ts"]
  ]

  @edit_fields @identity_fields ++
                 [
                   ts: ["event", "message", "ts"],
                   thread_ts: ["event", "message", "thread_ts"],
                   user: ["event", "message", "user"],
                   bot_id: ["event", "message", "bot_id"],
                   app_id: ["event", "message", "app_id"],
                   editor: ["event", "message", "edited", "user"],
                   edited_ts: ["event", "message", "edited", "ts"],
                   text: ["event", "message", "text"]
                 ]

  @deletion_fields @identity_fields ++
                     [
                       ts: ["event", "deleted_ts"],
                       thread_ts: ["event", "previous_message", "thread_ts"],
                       user: ["event", "previous_message", "user"],
                       bot_id: ["event", "previous_message", "bot_id"],
                       app_id: ["event", "previous_message", "app_id"]
                     ]

  @previous_ts ["event", "previous_message", "ts"]

  @doc false
  def trigger_events, do: Map.keys(@trigger_events)

  @doc false
  def normalize_signal("message", payload) do
    change_signal(payload, MessageChange.subtypes(), @channel_types)
  end

  def normalize_signal(event, payload) when is_map_key(@trigger_events, event) do
    {subtype, channel_types} = Map.fetch!(@trigger_events, event)
    change_signal(payload, [subtype], channel_types)
  end

  defp change_signal(
         %{"type" => "event_callback", "event" => %{"type" => "message"} = event} = payload,
         subtypes,
         channel_types
       ) do
    fields = fields(event)

    with :ok <- require_subtype(event, subtypes),
         :ok <- require_channel_type(event, channel_types),
         :ok <- require_edit(event),
         {:ok, attrs} <- attrs(payload, fields),
         {:ok, change} <- build(attrs, fields),
         :ok <- require_same_source(payload, change, fields) do
      {:ok, to_signal(change)}
    end
  end

  defp change_signal(_payload, _subtypes, _channel_types) do
    {:error,
     Error.provider("Unsupported Slack event",
       provider: :slack,
       reason: :unsupported_event
     )}
  end

  defp require_subtype(event, subtypes) do
    subtype = Data.get(event, "subtype")

    if subtype in subtypes do
      :ok
    else
      {:error,
       Error.provider("Unsupported Slack message subtype",
         provider: :slack,
         reason: :unsupported_message_subtype,
         details: %{subtype: subtype}
       )}
    end
  end

  defp require_channel_type(event, channel_types) do
    channel_type = Data.get(event, "channel_type")

    if channel_type in channel_types do
      :ok
    else
      {:error,
       Error.provider("Unsupported Slack message channel type",
         provider: :slack,
         reason: :unsupported_channel_type,
         details: %{channel_type: channel_type}
       )}
    end
  end

  # Slack also sends `message_changed` when it unfurls a link or updates a
  # thread parent's replies. Only `message.edited` marks an edit.
  defp require_edit(%{"subtype" => "message_changed"} = event) do
    with %{} = message <- Data.get(event, "message"),
         nil <- Data.get(message, "edited") do
      {:error,
       Error.provider("Slack message change is no edit",
         provider: :slack,
         reason: :not_an_edit
       )}
    else
      # An edit, or a message that is no map, which attrs/2 reports.
      _edited_or_malformed -> :ok
    end
  end

  defp require_edit(_deletion), do: :ok

  # A deletion reads no text: the deleted text is only in `previous_message`.
  defp fields(%{"subtype" => "message_deleted"}), do: @deletion_fields
  defp fields(_edit), do: @edit_fields

  defp attrs(payload, fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {key, path}, {:ok, attrs} ->
      case value_at(payload, path, []) do
        {:ok, value} -> {:cont, {:ok, Map.put(attrs, key, blank_to_nil(key, value))}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # The value at `path`, nil when a map on the way lacks the next key, or an
  # error that names the first step that is no map.
  defp value_at(value, [], _walked), do: {:ok, value}
  defp value_at(nil, _path, _walked), do: {:ok, nil}

  defp value_at(map, [key | rest], walked) when is_map(map),
    do: value_at(Data.get(map, key), rest, [key | walked])

  defp value_at(_other, _path, walked), do: {:error, invalid(Enum.reverse(walked))}

  # Like `Data.compact/1`, an empty ID or timestamp counts as absent. An
  # empty text is the text of the edit.
  defp blank_to_nil(:text, value), do: value
  defp blank_to_nil(_key, ""), do: nil
  defp blank_to_nil(_key, value), do: value

  defp build(attrs, fields) do
    case MessageChange.new(attrs) do
      {:ok, change} ->
        {:ok, change}

      {:error, [%Zoi.Error{path: [key | _rest]} | _errors]} ->
        {:error, invalid(Keyword.fetch!(fields, key))}
    end
  end

  # `previous_message`, when Slack sends it, must be the same message.
  defp require_same_source(payload, %MessageChange{ts: ts}, fields) do
    case value_at(payload, @previous_ts, []) do
      {:ok, previous} when previous in [nil, "", ts] ->
        :ok

      {:ok, previous} when is_binary(previous) ->
        {:error,
         Error.provider("Slack message change names two messages",
           provider: :slack,
           reason: :conflicting_message_change,
           details: %{
             field: path_name(Keyword.fetch!(fields, :ts)),
             conflicts_with: path_name(@previous_ts)
           }
         )}

      {:ok, _other} ->
        {:error, invalid(@previous_ts)}

      {:error, _reason} = error ->
        error
    end
  end

  defp path_name(path), do: Enum.join(path, ".")

  defp to_signal(%MessageChange{text: text} = change) do
    change
    |> Map.from_struct()
    |> Map.delete(:text)
    |> Data.compact()
    |> put_text(text)
  end

  defp put_text(signal, nil), do: signal
  defp put_text(signal, text), do: Map.put(signal, :text, text)

  defp invalid(path) do
    Error.provider("Slack message change is malformed",
      provider: :slack,
      reason: :invalid_message_change,
      details: %{field: path_name(path)}
    )
  end
end
