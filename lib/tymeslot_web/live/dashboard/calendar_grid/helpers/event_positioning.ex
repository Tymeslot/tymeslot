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

  # Prefers the event's own palette colour override (mapped to a Tailwind class
  # via `EventColour`) when set; otherwise falls back to the per-integration
  # colour. An unrecognised stored value (e.g. a raw inbound provider colour)
  # resolves to a neutral class via `EventColour` and never crashes.
  @spec color_for_event(map(), map()) :: String.t()
  def color_for_event(assigns, event) do
    case EventColour.tailwind_class(Map.get(event, :colour)) do
      nil ->
        color_class_for_integration(assigns.integration_colors, event.calendar_integration_id)

      class ->
        class
    end
  end

  @spec event_display_date(map(), String.t()) :: Date.t()
  def event_display_date(%{all_day: true, start_date: %Date{} = date}, _timezone), do: date

  def event_display_date(%{start_at: %DateTime{} = start_at}, timezone) do
    start_at |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
  end
end
