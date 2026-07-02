defmodule Tymeslot.Integrations.Calendar.ColourResolver do
  @moduledoc """
  Resolves the palette key to display for an event: the user's durable override
  wins, else the provider-synced colour, else `nil` (caller applies its own
  source/integration default). Shared by the agenda and the calendar grid so
  both surfaces agree.
  """

  @spec resolve(override :: String.t() | nil, provider_colour :: String.t() | nil) ::
          String.t() | nil
  def resolve(override, _provider) when is_binary(override), do: override
  def resolve(_override, provider) when is_binary(provider), do: provider
  def resolve(_override, _provider), do: nil
end
