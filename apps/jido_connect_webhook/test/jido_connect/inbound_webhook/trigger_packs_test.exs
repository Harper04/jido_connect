defmodule Jido.Connect.InboundWebhook.TriggerPacksTest do
  use ExUnit.Case, async: true

  alias Jido.Connect.Catalog
  alias Jido.Connect.InboundWebhook

  test "receiver trigger pack exposes only inbound delivery" do
    assert [pack] = InboundWebhook.trigger_packs()
    assert pack.id == :webhook_receiver
    assert pack.filters == %{provider: :webhook, type: :trigger}

    results =
      Catalog.search_tools("webhook",
        modules: [InboundWebhook],
        packs: InboundWebhook.trigger_packs(),
        pack: :webhook_receiver
      )

    assert Enum.map(results, & &1.tool.id) == ["webhook.inbound.delivery"]

    assert {:ok, descriptor} =
             Catalog.describe_tool("webhook.inbound.delivery",
               modules: [InboundWebhook],
               packs: InboundWebhook.trigger_packs(),
               pack: :webhook_receiver
             )

    assert descriptor.tool.type == :trigger
  end

  test "capabilities are separate from trigger packs" do
    assert InboundWebhook.verifier_capabilities() == %{
             id: :webhook_verifier,
             capabilities: [:hmac_verification]
           }

    assert InboundWebhook.receiver_capabilities() == %{
             id: :webhook_receiver,
             capabilities: [:hmac_verification, :inbound_delivery]
           }

    assert InboundWebhook.capability_sets() == [
             InboundWebhook.verifier_capabilities(),
             InboundWebhook.receiver_capabilities()
           ]
  end
end
