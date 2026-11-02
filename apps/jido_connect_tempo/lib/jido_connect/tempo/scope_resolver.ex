defmodule Jido.Connect.Tempo.ScopeResolver do
  @moduledoc """
  Local labels of the Tempo provider and the grants that satisfy them.

  Tempo actions require five local labels: `tempo.worklogs.read`,
  `tempo.worklogs.write`, `tempo.accounts.read`, `tempo.periods.read` and
  `tempo.approvals.read`. The runtime checks `required -- connection.scopes`,
  so a label counts only when the host has recorded it in
  `connection.scopes`:

  - API token: Tempo does not report a token's rights, so the host records
    the labels the user granted when creating the token.
  - OAuth: the host records `granted_labels/1` of the token response's
    `scope`.

  `granted_labels/1` maps Tempo's `<area>:view` and `<area>:manage` grants
  one to one: `worklogs:view` to `tempo.worklogs.read`, `worklogs:manage` to
  `tempo.worklogs.write`, and `accounts:view`, `periods:view` and
  `approvals:view` to the read labels of their areas. A manage grant implies
  no view label. Other grants, such as `teams:view` or the coarse `read` and
  `write` of Tempo's OpenAPI example, map to no label.

  `required_scopes/3` resolves an operation through `operations/0`, which
  each Tempo action extends with its labels. An operation without an entry
  fails closed with a `Jido.Connect.Error.ConfigError`.
  """

  alias Jido.Connect.{Authorization, Error, Scope}

  @grants [
    {"worklogs:view", "tempo.worklogs.read"},
    {"worklogs:manage", "tempo.worklogs.write"},
    {"accounts:view", "tempo.accounts.read"},
    {"periods:view", "tempo.periods.read"},
    {"approvals:view", "tempo.approvals.read"}
  ]

  @labels Enum.map(@grants, fn {_grant, label} -> label end)

  # Operation ID => labels. Each Tempo action adds its entry here.
  @operations %{}

  @doc "Returns the five local labels in declaration order."
  @spec labels() :: [String.t()]
  def labels, do: @labels

  @doc "Returns the labels each operation requires."
  @spec operations() :: %{String.t() => [String.t()]}
  def operations, do: @operations

  @doc """
  Returns the labels that a recorded Tempo grant satisfies.

  `scope` is the `scope` of an OAuth token response, as a space-separated
  string or a list.
  """
  @spec granted_labels(String.t() | [String.t()] | nil) :: [String.t()]
  def granted_labels(scope) do
    granted = scope |> Scope.parse() |> MapSet.new()
    for {grant, label} <- @grants, MapSet.member?(granted, grant), do: label
  end

  @doc "Returns the labels an operation requires, or a configuration error."
  @spec required_scopes(map(), map(), term()) :: [String.t()] | {:error, Error.ConfigError.t()}
  def required_scopes(operation, _input, _connection) do
    operation_id = Authorization.operation_id(operation)

    Map.get_lazy(@operations, operation_id, fn ->
      {:error,
       Error.config("Tempo operation has no scope mapping",
         key: :scope_resolver,
         details: %{operation_id: operation_id}
       )}
    end)
  end
end
