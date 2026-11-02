defmodule Jido.Connect.Jira.Client.Normalizer.MissingFieldsTest do
  use ExUnit.Case, async: true

  # `missing_fields` of `Normalizer.issue/2` on the recorded read of JCL-3
  # (`issue_context.7`), whose `fields` hold summary, description, status,
  # assignee, priority, labels, duedate, project, created and updated.

  alias Jido.Connect.Jira.Client.Normalizer
  alias Jido.Connect.TestSupport.LiveSmoke

  setup do
    %{payload: LiveSmoke.fixture!(:jira, "issue_context.7")}
  end

  test "lists nothing when no fields were requested", %{payload: payload} do
    assert {:ok, %{missing_fields: []}} = Normalizer.issue(payload)
  end

  test "lists requested keys that the payload leaves out, in request order", %{payload: payload} do
    assert {:ok, %{missing_fields: ["parent", "customfield_10001"]}} =
             Normalizer.issue(payload,
               requested_fields: ["summary", "parent,duedate", " customfield_10001 ", "parent"]
             )
  end

  test "skips selectors other than *all, exclusions and top-level properties", %{payload: payload} do
    assert {:ok, %{missing_fields: []}} =
             Normalizer.issue(payload,
               requested_fields: ["*navigable", "key", "id", "-parent", "parent"]
             )
  end

  test "lists every requested key for a payload without a fields object", %{payload: payload} do
    assert {:ok, %{missing_fields: ["summary", "duedate"]}} =
             Normalizer.issue(Map.delete(payload, "fields"),
               requested_fields: ["summary", "duedate"]
             )
  end
end
