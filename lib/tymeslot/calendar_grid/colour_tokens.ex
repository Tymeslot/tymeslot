defmodule Tymeslot.CalendarGrid.ColourTokens do
  @moduledoc """
  CSS colour token names for the calendar's client-drawn grid.

  The grid is drawn by JavaScript, which sets `--cal-ev: var(--color-<token>)`
  on each event, so it needs the token rather than the class. The token is
  the class without its `bg-` prefix, which keeps the palette defined once,
  in `Tymeslot.Integrations.Calendar.EventColour` and `base/variables.css`.

  `"booking"` is the bookings' token: `--color-booking` points at the
  surface's own booking colour rather than a palette entry.
  """

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.EventColour

  @booking "booking"

  @doc "The token for each account, keyed by integration id."
  @spec for_integrations([map()]) :: %{integer() => String.t()}
  def for_integrations(integrations) do
    integrations
    |> CalendarGrid.integration_colour_classes()
    |> Map.new(fn {id, class} -> {id, token(class)} end)
  end

  @doc """
  The token for each calendar, keyed by `{integration_id, calendar_id}`: the
  tokens of `CalendarGrid.calendar_colour_classes/2`, so the calendar and
  every other place that paints with the classes agree.
  """
  @spec for_calendars([map()], [map()]) :: %{{integer(), String.t()} => String.t()}
  def for_calendars(integrations, appearances) do
    integrations
    |> CalendarGrid.calendar_colour_classes(appearances)
    |> Map.new(fn {key, class} -> {key, token(class)} end)
  end

  @doc """
  The token an event paints with: its own colour, then its calendar's, then
  its account's, then the neutral fallback. A booking gets `"booking"`,
  unless the organiser chose it a colour (`with_override/2`).
  """
  @spec for_event(map(), map(), map()) :: String.t()
  def for_event(%{kind: :booking} = booking, _integration_tokens, _calendar_tokens),
    do: booking |> Map.get(:colour) |> EventColour.tailwind_class() |> token() || @booking

  def for_event(event, integration_tokens, calendar_tokens) do
    integration_id = Map.get(event, :calendar_integration_id)

    with nil <- event |> Map.get(:colour) |> EventColour.tailwind_class() |> token(),
         nil <- Map.get(calendar_tokens, {integration_id, Map.get(event, :provider_calendar_id)}),
         nil <- Map.get(integration_tokens, integration_id) do
      token(EventColour.fallback_class())
    end
  end

  @doc """
  `event` as the organiser has chosen to see it: with the colour of their
  override on it (`Calendar.overrides_for/1`), for painting only. A calendar
  event's is keyed `{:external, integration_id, uid}`, a booking's
  `{:meeting, meeting_id}` (set from the dashboard home's agenda); an event
  without one is as it is.
  """
  @spec with_override(map(), map()) :: map()
  def with_override(event, overrides) when map_size(overrides) == 0, do: event

  def with_override(event, overrides) do
    case Map.fetch(overrides, override_key(event)) do
      {:ok, colour} -> Map.put(event, :colour, colour)
      :error -> event
    end
  end

  defp override_key(%{kind: :booking} = booking), do: {:meeting, Map.get(booking, :meeting_id)}

  defp override_key(event),
    do: {:external, Map.get(event, :calendar_integration_id), Map.get(event, :uid)}

  @doc "The neutral token for anything without a colour of its own."
  @spec fallback() :: String.t()
  def fallback do
    "bg-" <> name = EventColour.fallback_class()
    name
  end

  defp token(nil), do: nil
  defp token("bg-" <> name), do: name
end
