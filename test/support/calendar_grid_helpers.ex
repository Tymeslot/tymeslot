defmodule Tymeslot.Test.CalendarGridHelpers do
  @moduledoc """
  Inserts provider calendar events at fixed times, for calendar grid tests
  whose assertions depend on where an event sits: a grid cell, a day
  boundary, an occurrence id built from the start time.

  The times are never defaulted. A test states them in its own scenario
  attributes (`@event %{summary: ..., start_at: ~U[...], end_at: ~U[...]}`)
  or builds them with `today_at/1`, so no assertion silently depends on the
  clock. A test that does not care when its event happens should call
  `insert(:provider_calendar_event, calendar_integration: integration)`
  directly instead.
  """

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  @doc """
  Inserts a synced, timed event of `integration` from `scenario`, a map that
  must carry `:start_at` and `:end_at`, with `attrs` merged over it.

  The event's provider defaults to the integration's own; `scenario` or
  `attrs` may override it, as a test of a mismatched provider would.
  """
  @spec insert_event(CalendarIntegrationSchema.t(), map(), map() | keyword()) ::
          ProviderCalendarEventSchema.t()
  def insert_event(integration, scenario, attrs \\ %{})

  def insert_event(
        %CalendarIntegrationSchema{} = integration,
        %{start_at: %DateTime{}, end_at: %DateTime{}} = scenario,
        attrs
      ) do
    base = %{
      calendar_integration: integration,
      provider: integration.provider,
      all_day: false,
      sync_state: "synced"
    }

    insert(:provider_calendar_event, base |> Map.merge(scenario) |> Map.merge(Map.new(attrs)))
  end

  @doc "Today (UTC) at `time`, for grid tests that must land on the visible day."
  @spec today_at(Time.t()) :: DateTime.t()
  def today_at(%Time{} = time), do: DateTime.new!(Date.utc_today(), time, "Etc/UTC")
end
