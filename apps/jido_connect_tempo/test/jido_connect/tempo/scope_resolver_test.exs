defmodule Jido.Connect.Tempo.ScopeResolverTest do
  use ExUnit.Case, async: true

  alias Jido.Connect.{Authorization, Connection, Error}
  alias Jido.Connect.Tempo
  alias Jido.Connect.Tempo.{Fixture, ScopeResolver}

  @labels [
    "tempo.worklogs.read",
    "tempo.worklogs.write",
    "tempo.accounts.read",
    "tempo.periods.read",
    "tempo.approvals.read"
  ]

  test "both auth profiles carry exactly the resolver's labels" do
    assert ScopeResolver.labels() == @labels

    for profile <- Tempo.integration().auth_profiles do
      assert profile.scopes == @labels
    end
  end

  describe "granted_labels/1" do
    test "maps the observed OAuth scope to all five labels" do
      scope = Fixture.observed!("oauth_token")["body"]["scope"]

      assert ScopeResolver.granted_labels(scope) == @labels
    end

    test "maps each grant to one label and implies no other" do
      assert ScopeResolver.granted_labels("periods:view worklogs:view") == [
               "tempo.worklogs.read",
               "tempo.periods.read"
             ]

      assert ScopeResolver.granted_labels(["worklogs:manage"]) == ["tempo.worklogs.write"]

      assert ScopeResolver.granted_labels(["approvals:view", "accounts:view"]) == [
               "tempo.accounts.read",
               "tempo.approvals.read"
             ]
    end

    test "ignores grants without a label, including the coarse read and write" do
      assert ScopeResolver.granted_labels("read write teams:view accounts:manage") == []
      assert ScopeResolver.granted_labels(nil) == []
    end
  end

  describe "required_scopes/3" do
    test "has no operations before the first Tempo action" do
      assert ScopeResolver.operations() == %{}
    end

    test "an operation without an entry fails closed" do
      assert {:error, %Error.ConfigError{key: :scope_resolver, details: details}} =
               ScopeResolver.required_scopes(%{action_id: "tempo.unknown"}, %{}, nil)

      assert details.operation_id == "tempo.unknown"
    end

    test "the runtime reports an unmapped operation as a configuration error" do
      operation = %{
        action_id: "tempo.unknown",
        auth_profiles: [:api_token, :oauth2_user],
        scope_resolver: ScopeResolver
      }

      assert {:configuration_error, %Error.ConfigError{}} =
               Authorization.connection_availability(operation, connection(@labels))
    end
  end

  # The runtime checks `required -- connection.scopes`, so a label counts
  # only when the host recorded it, for OAuth through granted_labels/1.
  test "only labels recorded in connection.scopes satisfy a requirement" do
    operation = %{action_id: "tempo.example", auth_profiles: [:oauth2_user], scopes: @labels}
    scope = Fixture.observed!("oauth_token")["body"]["scope"]

    assert {:available, @labels} =
             Authorization.connection_availability(
               operation,
               connection(ScopeResolver.granted_labels(scope))
             )

    assert {:missing_scopes, @labels} =
             Authorization.connection_availability(operation, connection(String.split(scope)))
  end

  defp connection(scopes) do
    Connection.new!(%{
      id: "tempo_conn_1",
      provider: :tempo,
      profile: :oauth2_user,
      tenant_id: "tenant_1",
      owner_type: :app_user,
      owner_id: "user_1",
      subject: %{account_id: "712020:acct-a"},
      status: :connected,
      scopes: scopes,
      metadata: %{api_origin: "https://api.us.tempo.io"}
    })
  end
end
