defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.EventPositioning do
  @moduledoc "CSS positioning helpers for timed calendar events: top offset, height, column layout, and colour assignment."

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

  @spec color_class_for_integration(map(), term()) :: String.t()
  def color_class_for_integration(integration_colors, integration_id) do
    index = Map.get(integration_colors, integration_id)
    calendar_color_class(index)
  end

  @spec color_dot(map(), map()) :: String.t()
  def color_dot(assigns, integration) do
    color_class_for_integration(assigns.integration_colors, integration.id)
  end

  @spec color_for_event(map(), map()) :: String.t()
  def color_for_event(assigns, event) do
    color_class_for_integration(assigns.integration_colors, event.calendar_integration_id)
  end

  @spec event_display_date(map(), String.t()) :: Date.t()
  def event_display_date(%{all_day: true, start_date: %Date{} = date}, _timezone), do: date

  def event_display_date(%{start_at: %DateTime{} = start_at}, timezone) do
    start_at |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
  end

  # Private helpers

  defp calendar_color_class(nil), do: "bg-calendar-fallback"
  defp calendar_color_class(index), do: "bg-calendar-#{index}"
end
