defmodule Jido.Connect.TestSupport.LiveSmoke.Recorder do
  @moduledoc false

  # Req adapter that `LiveSmoke.record/4` installs through a package's Req
  # options. It runs the Finch adapter and appends a response step that writes
  # each final response, sanitized, as a fixture file.

  use Agent

  alias Jido.Connect.TestSupport.LiveSmoke.Sanitize

  @step :live_smoke_record

  def start_link(session), do: Agent.start_link(fn -> session end, name: __MODULE__)

  def switch(session), do: Agent.update(__MODULE__, fn _previous -> session end)

  def run(%Req.Request{} = request) do
    request
    |> attach_step()
    |> Req.Finch.run()
  end

  defp attach_step(request) do
    if Keyword.has_key?(request.response_steps, @step) do
      request
    else
      Req.Request.append_response_steps(request, [{@step, &write_response/1}])
    end
  end

  defp write_response({request, response}) do
    session = Agent.get(__MODULE__, & &1)
    count = session.count + 1
    {fixture, sanitizer} = fixture(request, response, session.sanitizer)
    Sanitize.check_leaks!(fixture, sanitizer)

    path = Path.join(session.dir, file_name(session.name, count))
    File.mkdir_p!(session.dir)
    File.write!(path, [Jason.encode_to_iodata!(fixture, pretty: true), "\n"])

    Agent.update(__MODULE__, &%{&1 | count: count, sanitizer: sanitizer})
    {request, response}
  end

  defp fixture(request, response, sanitizer) do
    {path, sanitizer} = Sanitize.text(request.url.path || "/", sanitizer)
    {headers, sanitizer} = Sanitize.headers(response.headers, sanitizer)
    {body, sanitizer} = body(response.body, sanitizer)

    {%{
       "recorded_at" => Date.to_iso8601(Date.utc_today()),
       "request" => %{
         "method" => request.method |> to_string() |> String.upcase(),
         "path" => path
       },
       "status" => response.status,
       "headers" => headers,
       "body" => body
     }, sanitizer}
  end

  defp body(body, sanitizer) when is_map(body) or is_list(body),
    do: Sanitize.value(body, sanitizer)

  defp body(body, sanitizer) when is_binary(body) do
    if String.valid?(body) do
      Sanitize.text(body, sanitizer)
    else
      raise ArgumentError, "live smoke recordings hold JSON or UTF-8 text bodies only"
    end
  end

  defp body(_body, _sanitizer) do
    raise ArgumentError, "live smoke recordings hold JSON or UTF-8 text bodies only"
  end

  defp file_name(name, 1), do: "#{name}.json"
  defp file_name(name, count), do: "#{name}.#{count}.json"
end
