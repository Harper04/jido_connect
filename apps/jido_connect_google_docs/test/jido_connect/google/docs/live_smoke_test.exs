defmodule Jido.Connect.Google.Docs.LiveSmokeTest do
  @moduledoc """
  Live smoke checks against the Google Workspace test account.

      mix test --only live_smoke

  See `docs/live_smoke_tests.md` for the variables and the recording mode.
  """

  use ExUnit.Case, async: false
  use Jido.Connect.TestSupport.LiveSmoke

  alias Jido.Connect.Google.Docs.Client

  @tag env!(["GOOGLE_ACCESS_TOKEN", "GOOGLE_DOCS_SCRATCH_DOCUMENT_ID"])
  test "reads the scratch document", %{env: env} do
    LiveSmoke.record({:jido_connect_google, :google_req_options}, :google_docs, "document")

    assert {:ok, document} =
             Client.get_document(
               %{document_id: env["GOOGLE_DOCS_SCRATCH_DOCUMENT_ID"]},
               env["GOOGLE_ACCESS_TOKEN"]
             )

    assert is_map(document)
  end
end
