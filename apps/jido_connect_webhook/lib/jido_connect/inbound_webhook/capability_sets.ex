defmodule Jido.Connect.InboundWebhook.CapabilitySets do
  @moduledoc "Named inbound webhook capability sets."

  @type t :: %{
          required(:id) => atom(),
          required(:capabilities) => [atom()]
        }

  @doc "Returns all built-in inbound webhook capability sets."
  @spec all() :: [t()]
  def all, do: [verifier(), receiver()]

  @doc "Returns HMAC verification capabilities."
  @spec verifier() :: t()
  def verifier do
    %{
      id: :webhook_verifier,
      capabilities: [:hmac_verification]
    }
  end

  @doc "Returns verification and inbound delivery capabilities."
  @spec receiver() :: t()
  def receiver do
    %{
      id: :webhook_receiver,
      capabilities: [:hmac_verification, :inbound_delivery]
    }
  end
end
