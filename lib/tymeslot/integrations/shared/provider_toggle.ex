defmodule Tymeslot.Integrations.Shared.ProviderToggle do
  @moduledoc """
  Shared helpers for determining whether a provider type is enabled.

  Applies consistent rules for boolean, keyword, and map-based settings.
  """

  @doc """
  Returns whether a provider is enabled based on settings.

  ## Options
    * `:default_enabled` - fallback when a provider has no explicit entry (default: true)
  """
  @spec enabled?(map(), atom(), keyword()) :: boolean()
  def enabled?(settings, type, opts \\ []) when is_atom(type) and is_map(settings) do
    default_enabled = Keyword.get(opts, :default_enabled, true)

    case provider_setting(settings, type) do
      nil -> default_enabled
      value when is_boolean(value) -> value
      value when is_list(value) -> Keyword.get(value, :enabled, default_enabled)
      %{} = value -> Map.get(value, :enabled, default_enabled)
      _ -> default_enabled
    end
  end

  defp provider_setting(settings, type) do
    Map.get(settings, type) ||
      Map.get(settings, Atom.to_string(type))
  end
end
