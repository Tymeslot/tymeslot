defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.EventPositioning do
  @moduledoc "CSS positioning helpers for timed calendar events: top offset, height, column layout, and colour assignment."

  alias Tymeslot.Integrations.Calendar.EventColour

  @spec top_rem(DateTime.t(), String.t()) :: float()
  def top_rem(dt, tz \\ "UTC") do
    local_dt = DateTime.shift_zone!(dt, tz)
    minutes = local_dt.hour * 60 + local_dt.minute
    Float.round(minutes / 60 * 4, 3)
  end

  @spec height_rem(DateTime.t(), DateTime.t()) :: float()
  def height_rem(start_dt, end_dt) do
    duration_minutes = DateTime.diff(end_dt, start_dt, :second) / 60
    max(0.5, Float.round(duration_minutes / 60 * 4, 3))
  end

  @spec left_pct(integer(), integer()) :: float()
  def left_pct(col_idx, total_cols) do
    Float.round(col_idx / total_cols * 100, 2)
  end

  @spec width_pct(integer()) :: float()
  def width_pct(total_cols) do
    Float.round(1 / total_cols * 100, 2)
  end

  # `CalendarGrid.integration_colour_classes/1` resolves the class, so this is
  # a lookup with a fallback for the ids it does not cover: an event whose
  # integration was hidden, deleted, or is not the current user's.
  @spec color_class_for_integration(map(), term()) :: String.t()
  def color_class_for_integration(integration_colors, integration_id) do
    Map.get(integration_colors, integration_id, EventColour.fallback_class())
  end

  @spec color_dot(map(), map()) :: String.t()
  def color_dot(assigns, integration) do
    color_class_for_integration(assigns.integration_colors, integration.id)
  end

  # Precedence, first match winning: the event's own palette override, then the
  # organiser's colour for the calendar it sits in, then the integration's
  # colour, then the rotation. Every step is a lookup that may miss, so an event
  # whose calendar was deleted or never had a choice still paints. An
  # unrecognised stored value (e.g. a raw inbound provider colour) resolves to a
  # neutral class via `EventColour` and never crashes.
  @spec color_for_event(map(), map()) :: String.t()
  def color_for_event(assigns, event) do
    with nil <- EventColour.tailwind_class(Map.get(event, :colour)),
         nil <- calendar_colour(assigns, event) do
      color_class_for_integration(assigns.integration_colors, event.calendar_integration_id)
    end
  end

  # Read through `Map.get/3` on the assigns rather than `assigns.calendar_colors`:
  # this helper is called from function components that build their own assigns
  # maps in tests, and an absent key means "no per-calendar choices", not a crash.
  defp calendar_colour(assigns, event) do
    key = {event.calendar_integration_id, Map.get(event, :provider_calendar_id)}

    assigns
    |> Map.get(:calendar_colors, %{})
    |> Map.get(key)
  end

  @spec event_display_date(map(), String.t()) :: Date.t()
  def event_display_date(%{all_day: true, start_date: %Date{} = date}, _timezone), do: date

  def event_display_date(%{start_at: %DateTime{} = start_at}, timezone) do
    start_at |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
  end
end
