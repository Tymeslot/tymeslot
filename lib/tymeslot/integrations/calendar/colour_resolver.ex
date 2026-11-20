defmodule Tymeslot.Integrations.Calendar.ColourResolver do
  @moduledoc """
  Resolves the palette key to display for an event: the user's durable override
  wins, else the provider-synced colour, else `nil` (caller applies its own
  source/integration default). A cleared override (a `nil` colour) wins too,
  as no colour: the provider's copy may still carry the colour it cleared.
  Exposed to callers via `Tymeslot.Integrations.Calendar.resolve_event_colour/3`;
  used by the agenda.
  """

  @spec resolve(overrides :: map(), target :: tuple(), provider_colour :: String.t() | nil) ::
          String.t() | nil
  def resolve(overrides, target, provider) do
    case Map.fetch(overrides, target) do
      {:ok, override} -> override
      :error -> provider
    end
  end
end
