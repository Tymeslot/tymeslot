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
  its account's, then the neutral fallback. Bookings always get `"booking"`.
  """
  @spec for_event(map(), map(), map()) :: String.t()
  def for_event(%{kind: :booking}, _integration_tokens, _calendar_tokens), do: @booking

  def for_event(event, integration_tokens, calendar_tokens) do
    integration_id = Map.get(event, :calendar_integration_id)

    with nil <- event |> Map.get(:colour) |> EventColour.tailwind_class() |> token(),
         nil <- Map.get(calendar_tokens, {integration_id, Map.get(event, :provider_calendar_id)}),
         nil <- Map.get(integration_tokens, integration_id) do
      token(EventColour.fallback_class())
    end
  end

  @doc "The neutral token for anything without a colour of its own."
  @spec fallback() :: String.t()
  def fallback do
    "bg-" <> name = EventColour.fallback_class()
    name
  end

  defp token(nil), do: nil
  defp token("bg-" <> name), do: name
end
