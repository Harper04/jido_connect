defmodule Jido.Connect.WebhookDeliveryTest do
  use ExUnit.Case, async: true

  alias Jido.Connect.WebhookDelivery

  # Depth counts from the sanitized value: the map itself is level 0, so a
  # change's `from` below is level 4 and a value inside `detail` is level 5.
  @long String.duplicate("a", 600)

  describe "to_public_map/1" do
    test "keeps normalized signal values on level 4 within the byte, collection and key limits" do
      public = delivery() |> WebhookDelivery.to_public_map()

      assert %{
               "record" => %{
                 "changes" => [
                   %{
                     "field" => "state",
                     "from" => "open",
                     "to" => nil,
                     "note" => note,
                     "token" => "[redacted]",
                     "detail" => %{"kind" => "[truncated]"},
                     "values" => values,
                     "attrs" => attrs
                   }
                 ]
               }
             } = public.normalized_signal

      assert note == binary_part(@long, 0, 512) <> "...[truncated 88 bytes]"
      assert values == List.duplicate("[truncated]", 50) ++ ["[truncated 1 items]"]
      assert {1, kept} = Map.pop(attrs, "__truncated__")
      assert map_size(kept) == 50 and Enum.all?(Map.values(kept), &(&1 == "[truncated]"))
      assert {:ok, _json} = Jason.encode(public)
    end

    test "inspect/1 shows the same level of the normalized signal" do
      inspected =
        WebhookDelivery.verified!(:demo, event: "record.updated")
        |> WebhookDelivery.put_signal(%{
          record: %{changes: [%{from: "open", token: "secret-value"}]}
        })
        |> inspect()

      assert inspected =~ ~s("from" => "open")
      refute inspected =~ "secret-value"
    end

    test "keeps headers, payload and metadata at four levels" do
      public = delivery() |> WebhookDelivery.to_public_map()

      for part <- [public.headers, public.payload, public.metadata] do
        assert %{"record" => %{"changes" => [change]}} = part

        assert change == %{
                 "field" => "[truncated]",
                 "from" => "[truncated]",
                 "to" => "[truncated]",
                 "note" => "[truncated]",
                 "token" => "[redacted]",
                 "detail" => "[truncated]",
                 "values" => "[truncated]",
                 "attrs" => "[truncated]"
               }
      end
    end
  end

  defp delivery do
    WebhookDelivery.verified!(:demo,
      delivery_id: "delivery_1",
      event: "record.updated",
      headers: nested(),
      payload: nested(),
      metadata: nested()
    )
    |> WebhookDelivery.put_signal(nested())
  end

  defp nested do
    %{
      record: %{
        changes: [
          %{
            field: "state",
            from: "open",
            to: nil,
            note: @long,
            token: "secret-value",
            detail: %{kind: "nested"},
            values: Enum.to_list(1..51),
            attrs: Map.new(1..51, &{"attr_#{&1}", &1})
          }
        ]
      }
    }
  end
end
