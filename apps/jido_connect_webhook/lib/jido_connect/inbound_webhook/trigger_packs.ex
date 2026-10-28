defmodule Jido.Connect.InboundWebhook.TriggerPacks do
  @moduledoc "Curated trigger packs for inbound webhook subscriptions."

  alias Jido.Connect.Catalog.Pack

  @doc "Returns all built-in inbound webhook trigger packs."
  @spec all() :: [Pack.t()]
  def all, do: [receiver()]

  @doc "Returns the inbound delivery trigger pack."
  @spec receiver() :: Pack.t()
  def receiver do
    Pack.new!(%{
      id: :webhook_receiver,
      label: "Webhook receiver",
      description:
        "Inbound webhook delivery trigger with verification and replay-deduplication metadata.",
      filters: %{provider: :webhook, type: :trigger},
      allowed_tools: ["webhook.inbound.delivery"],
      metadata: %{package: :jido_connect_webhook, risk: :read}
    })
  end
end
