ExUnit.start(exclude: [:live_smoke])

unless Code.ensure_loaded?(Jido.Connect.TestSupport.LiveSmoke) do
  Code.require_file("../../jido_connect/test/support/live_smoke.ex", __DIR__)
end

defmodule Jido.Connect.Tempo.Fixture do
  @moduledoc false

  # Replays fixtures under test/fixtures/tempo. `recorded/` holds live
  # recordings made with LiveSmoke.record/4; `observed/` holds response shapes
  # seen live but not recordable, each with a `source` note.

  @root Path.join([__DIR__, "fixtures", "tempo"])

  def recorded!(name), do: read!("recorded", name)
  def observed!(name), do: read!("observed", name)

  @doc """
  Sends a recorded response with its status, content type and body.

  `:status` and `:headers` replace the recorded status or add headers, for
  responses that cannot be triggered safely, such as 429 and 5xx. `:body` is
  a function that changes the recorded body, for malformed or hostile pages.
  """
  def respond(conn, name, opts \\ []) do
    fixture = recorded!(name)
    headers = content_type(fixture) ++ Keyword.get(opts, :headers, [])
    status = Keyword.get(opts, :status, fixture["status"])
    body = Keyword.get(opts, :body, & &1).(fixture["body"])

    headers
    |> Enum.reduce(conn, fn {key, value}, conn -> Plug.Conn.put_resp_header(conn, key, value) end)
    |> Plug.Conn.send_resp(status, body(body))
  end

  defp read!(kind, name) do
    [@root, kind, name <> ".json"] |> Path.join() |> File.read!() |> Jason.decode!()
  end

  defp content_type(%{"headers" => %{"content-type" => [value | _rest]}}),
    do: [{"content-type", value}]

  defp content_type(_fixture), do: []

  defp body(body) when is_binary(body), do: body
  defp body(nil), do: ""
  defp body(body), do: Jason.encode!(body)
end

# Ensure Req.Test.Ownership is running so that client tests can run without the
# full application supervision tree.
unless Process.whereis(Req.Test.Ownership) do
  {:ok, _} = Req.Test.Ownership.start_link(name: Req.Test.Ownership)
end
