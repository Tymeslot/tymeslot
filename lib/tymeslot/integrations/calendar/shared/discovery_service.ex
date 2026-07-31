defmodule Tymeslot.Integrations.Calendar.Shared.DiscoveryService do
  @moduledoc """
  Shared, non-boundary helpers for CalDAV-based calendar discovery:
  discovery-cache key derivation and standardizing provider results into
  `CalendarEntry` structs.

  The discovery boundary itself — provider resolution, rate limiting, and
  result caching/invalidation — lives in
  `Tymeslot.Integrations.Calendar.Discovery`, the single choke point every
  discovery call (credentials-based or integration-based) goes through. This
  module holds only the residue every discovery path shares, with no
  provider dispatch and no metering of its own.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEntry

  @doc """
  Builds the `Tymeslot.Integrations.Calendar.Shared.DiscoveryCache` key for a
  CalDAV discovery request against raw connection config.
  """
  @spec build_cache_key(atom(), %{
          required(:base_url) => String.t(),
          required(:username) => String.t(),
          optional(atom()) => term()
        }) :: {atom(), String.t()}
  def build_cache_key(provider, config) do
    user_id = "#{config[:username]}@#{extract_domain(config[:base_url])}"
    {provider, user_id}
  end

  @doc """
  Standardizes calendar data structure across providers.

  Accepts either `CalendarEntry` structs (providers already converted to the
  producer edge) or raw provider maps (providers not yet converted), and
  normalises both into `CalendarEntry` structs via `CalendarEntry.normalize/1`
  and `CalendarEntry.with_defaults/1`.

  ## Parameters
  - `calendars` - List of calendar entries or maps from various providers
  - `provider` - The provider type, used only as a fallback id source when a
    calendar has neither `:id` nor `:path`/`:href`

  ## Returns
  - List of standardized `CalendarEntry` structs
  """
  @spec standardize_calendar_data(list(CalendarEntry.t() | map()), atom()) ::
          list(CalendarEntry.t())
  def standardize_calendar_data(calendars, provider) do
    Enum.map(calendars, fn calendar ->
      entry = calendar |> CalendarEntry.normalize() |> CalendarEntry.with_defaults()

      if is_nil(entry.id) do
        %{entry | id: generate_calendar_id(entry, provider)}
      else
        entry
      end
    end)
  end

  # Private functions

  defp extract_domain(url) do
    uri = URI.parse(url)
    uri.host || url
  end

  # Generate a unique ID for calendars that have neither an `:id` nor a
  # `:path`/`:href` to fall back to (`CalendarEntry.with_defaults/1` already
  # covers the common case of deriving one from the other).
  defp generate_calendar_id(%CalendarEntry{} = entry, provider) do
    :crypto.hash(:md5, "#{provider}:#{entry.path}:#{entry.name}")
    |> Base.encode16(case: :lower)
    |> String.slice(0..7)
  end
end
