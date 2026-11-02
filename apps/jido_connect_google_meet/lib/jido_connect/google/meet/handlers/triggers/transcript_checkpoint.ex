defmodule Jido.Connect.Google.Meet.Handlers.Triggers.TranscriptCheckpoint do
  @moduledoc false

  # The checkpoint of `google.meet.transcript.available`: a watermark on
  # conference end times, the settled records that ended exactly at the
  # watermark, and the records still waiting for a generated transcript.
  # Hosts persist it as the JSON string `encode/1` returns. The package
  # README documents the shape and the bounds.

  alias Jido.Connect.Error
  alias Jido.Connect.Google.Checkpoint

  @version 1

  # A pending record leaves the checkpoint once it is settled, older than
  # `@max_pending_age_seconds`, or beyond the `@max_pending` most recent ones.
  @max_pending 50
  @max_pending_age_seconds 24 * 60 * 60

  defstruct [:watermark, settled_at_watermark: [], pending: []]

  @doc "Starts a checkpoint whose watermark is `now`."
  def new(%DateTime{} = now), do: %__MODULE__{watermark: now}

  @doc """
  Builds the conference record filter for end times at or after `watermark`.

  Every conference record started after 1970, so the `start_time` clause
  leaves the matches unchanged. It keeps paging stable: live, with the
  `end_time` clause alone, a later page often repeated the first record under
  a fresh page token.
  """
  def window_filter(%DateTime{} = watermark) do
    ~s(end_time>="#{DateTime.to_iso8601(watermark)}" AND start_time>="1970-01-01T00:00:00Z")
  end

  @doc "True when the record is pending or settled at the watermark."
  def known?(%__MODULE__{} = checkpoint, name) do
    name in checkpoint.settled_at_watermark or
      Enum.any?(checkpoint.pending, &(&1.name == name))
  end

  @doc """
  Advances the checkpoint over the records checked in one poll.

  Each checked record carries `name`, `end_time`, `emitted` and `settled?`.
  The watermark moves to the latest end time. Open records stay pending
  within the count and age bounds. Records that settle or leave the pending
  set at the watermark are kept by name, so the inclusive window filter lists
  them again without effect.
  """
  def advance(%__MODULE__{} = checkpoint, checked, %DateTime{} = now) do
    watermark = Enum.reduce(checked, checkpoint.watermark, &latest(&1.end_time, &2))
    {open, settled} = Enum.split_with(checked, &(not &1.settled?))
    {pending, dropped} = bound_pending(open, now)

    carried =
      if DateTime.compare(watermark, checkpoint.watermark) == :eq,
        do: checkpoint.settled_at_watermark,
        else: []

    at_watermark =
      for record <- settled ++ dropped, DateTime.compare(record.end_time, watermark) == :eq do
        record.name
      end

    %__MODULE__{
      watermark: watermark,
      settled_at_watermark: Enum.uniq(carried ++ at_watermark),
      pending: Enum.map(pending, &Map.take(&1, [:name, :end_time, :emitted]))
    }
  end

  defp bound_pending(open, now) do
    cutoff = DateTime.add(now, -@max_pending_age_seconds, :second)
    {recent, aged} = Enum.split_with(open, &(DateTime.compare(&1.end_time, cutoff) != :lt))

    {pending, overflow} =
      recent
      |> Enum.sort_by(& &1.end_time, {:desc, DateTime})
      |> Enum.split(@max_pending)

    {pending, aged ++ overflow}
  end

  @doc "Decodes a checkpoint string written by `encode/1`."
  def decode(checkpoint) when is_binary(checkpoint) do
    with {:ok,
          %{
            "version" => @version,
            "watermark" => watermark,
            "settled_at_watermark" => settled,
            "pending" => pending
          }} <- JSON.decode(checkpoint),
         {:ok, watermark} <- parse_time(watermark),
         true <- names?(settled),
         {:ok, pending} <- decode_pending(pending) do
      {:ok, %__MODULE__{watermark: watermark, settled_at_watermark: settled, pending: pending}}
    else
      _invalid -> invalid_checkpoint()
    end
  end

  def decode(_checkpoint), do: invalid_checkpoint()

  @doc "Encodes a checkpoint as the JSON string hosts persist."
  def encode(%__MODULE__{} = checkpoint) do
    JSON.encode!(%{
      "version" => @version,
      "watermark" => DateTime.to_iso8601(checkpoint.watermark),
      "settled_at_watermark" => checkpoint.settled_at_watermark,
      "pending" =>
        Enum.map(checkpoint.pending, fn record ->
          %{
            "name" => record.name,
            "end_time" => DateTime.to_iso8601(record.end_time),
            "emitted" => record.emitted
          }
        end)
    })
  end

  @doc "Parses an RFC 3339 timestamp from the Meet API or a checkpoint."
  def parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> {:ok, time}
      {:error, _reason} -> :error
    end
  end

  def parse_time(_value), do: :error

  defp decode_pending(pending) when is_list(pending) do
    Enum.reduce_while(pending, {:ok, []}, fn
      %{"name" => name, "end_time" => end_time, "emitted" => emitted}, {:ok, acc}
      when is_binary(name) ->
        with {:ok, end_time} <- parse_time(end_time),
             true <- names?(emitted) do
          {:cont, {:ok, [%{name: name, end_time: end_time, emitted: emitted} | acc]}}
        else
          _invalid -> {:halt, :error}
        end

      _invalid, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, pending} -> {:ok, Enum.reverse(pending)}
      :error -> :error
    end
  end

  defp decode_pending(_pending), do: :error

  defp names?(names), do: is_list(names) and Enum.all?(names, &is_binary/1)

  defp latest(time, other), do: if(DateTime.compare(time, other) == :gt, do: time, else: other)

  defp invalid_checkpoint do
    {:error,
     Error.validation("Google Meet transcript checkpoint is invalid",
       reason: :invalid_checkpoint,
       details: %{field: :checkpoint, checkpoint_reset: Checkpoint.reset_guidance()}
     )}
  end
end
