defmodule Jido.Connect.Tempo.Handlers.Actions.ListOwnWorklogs do
  @moduledoc false

  # The account is the connection's subject.account_id, bound in the
  # request; the input carries only the range.

  alias Jido.Connect.Tempo.{Client, Worklog}

  def run(%{from: from, to: to}, runtime) do
    client = Client.resolve(runtime)

    with {:ok, request} <- Client.request_context(runtime),
         {:ok, worklogs} <- client.list_own_worklogs(request, from: from, to: to) do
      {:ok,
       %{
         account_id: request.account_id,
         from: from,
         to: to,
         worklogs: Enum.map(worklogs, &Worklog.to_map/1),
         complete: true
       }}
    end
  end
end
