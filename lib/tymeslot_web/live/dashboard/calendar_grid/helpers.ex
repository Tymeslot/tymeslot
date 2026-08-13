defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers do
  @moduledoc "Facade delegating to focused sub-modules for the CalendarGridComponent."

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.DataLoading
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.EventPositioning
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.MonthSpanLayout
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.OverlapLayout
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.PreferenceHelpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.TimeFormatting

  # Data loading

  defdelegate load_integrations(socket), to: DataLoading
  defdelegate check_staleness(socket), to: DataLoading
  defdelegate load_events(socket), to: DataLoading
  defdelegate precompute_derived(socket), to: DataLoading
  defdelegate range_for_view(assigns), to: DataLoading

  # Event positioning

  defdelegate top_rem(dt), to: EventPositioning
  defdelegate top_rem(dt, tz), to: EventPositioning
  defdelegate height_rem(start_dt, end_dt), to: EventPositioning
  defdelegate left_pct(col_idx, total_cols), to: EventPositioning
  defdelegate width_pct(total_cols), to: EventPositioning

  defdelegate color_class_for_integration(integration_colors, integration_id),
    to: EventPositioning

  defdelegate color_dot(assigns, integration), to: EventPositioning
  defdelegate color_for_event(assigns, event), to: EventPositioning
  defdelegate event_display_date(event, timezone), to: EventPositioning
  defdelegate booking?(event), to: EventPositioning
  defdelegate open_event_attrs(event), to: EventPositioning

  # Time formatting

  defdelegate format_time_range(event), to: TimeFormatting
  defdelegate format_time_range(event, fmt), to: TimeFormatting
  defdelegate format_display_time_range(event), to: TimeFormatting
  defdelegate format_display_time_range(event, fmt), to: TimeFormatting
  defdelegate format_display_time_range(event, fmt, timezone), to: TimeFormatting
  defdelegate format_time_range_in_tz(event, timezone), to: TimeFormatting
  defdelegate format_time_range_in_tz(event, timezone, fmt), to: TimeFormatting
  defdelegate tz_abbr(timezone), to: TimeFormatting
  defdelegate datetime_to_local_parts(dt, timezone), to: TimeFormatting
  defdelegate format_hour(hour, assigns), to: TimeFormatting
  defdelegate user_timezone(assigns), to: TimeFormatting
  defdelegate user_tz_abbr(assigns), to: TimeFormatting
  defdelegate url?(str), to: TimeFormatting
  defdelegate linkify_text(text), to: TimeFormatting

  # Preference helpers

  defdelegate week_start(date, assigns), to: PreferenceHelpers
  defdelegate col_count(assigns), to: PreferenceHelpers
  defdelegate day_header_class(day), to: PreferenceHelpers
  defdelegate day_header_class(day, timezone), to: PreferenceHelpers
  defdelegate period_label(assigns), to: PreferenceHelpers
  defdelegate view_label(view), to: PreferenceHelpers
  defdelegate navigate_month(date, delta), to: PreferenceHelpers
  defdelegate month_cell_class(day, assigns), to: PreferenceHelpers
  defdelegate week_start_atom(assigns), to: PreferenceHelpers
  defdelegate show_weekends?(assigns), to: PreferenceHelpers
  defdelegate show_week_numbers?(assigns), to: PreferenceHelpers
  defdelegate time_format(assigns), to: PreferenceHelpers
  defdelegate safe_view_atom(view), to: PreferenceHelpers
  defdelegate assign_view_from_preferences(socket), to: PreferenceHelpers
  defdelegate week_number(date), to: PreferenceHelpers
  defdelegate day_name_headers(assigns), to: PreferenceHelpers
  defdelegate month_matrix(date, week_start), to: PreferenceHelpers

  # Overlap layout

  defdelegate positioned_events_for_day(assigns, date), to: OverlapLayout
  defdelegate overflow_events_for_day(assigns, date), to: OverlapLayout
  defdelegate layout_for_day(assigns, date), to: OverlapLayout
  defdelegate overlap_layout(events), to: OverlapLayout
  defdelegate cross_integration_overlap_ids(events), to: OverlapLayout
  defdelegate cross_integration_overlap_ids_for_day(assigns, date), to: OverlapLayout

  # Month-grid multi-day / all-day bar layout

  defdelegate week_layout(assigns, week_days), to: MonthSpanLayout
  defdelegate chip_events(assigns, date), to: MonthSpanLayout

  # General-purpose event filtering (remains in facade)

  @spec visible_events(map()) :: list()
  def visible_events(assigns), do: assigns.visible_events

  @spec visible_days(map()) :: [Date.t()]
  def visible_days(assigns), do: assigns.visible_days

  @spec day_events(map(), Date.t()) :: list()
  def day_events(assigns, date) do
    tz = assigns.user_timezone

    Enum.filter(visible_events(assigns), fn e ->
      not e.all_day and event_spans_day?(e, date, tz)
    end)
  end

  @spec all_day_events_for_day(map(), Date.t()) :: list()
  def all_day_events_for_day(assigns, date) do
    Enum.filter(visible_events(assigns), fn event ->
      # end_date stores the exclusive end (iCal DTEND for all-day events is exclusive),
      # so the event covers `date` only when start_date <= date < end_date.
      event.all_day and
        Date.compare(event.start_date, date) != :gt and
        Date.compare(event.end_date, date) == :gt
    end)
  end

  # Private helpers

  defp event_spans_day?(event, date, tz) do
    {day_start, day_end} = OverlapLayout.day_boundary_utc(date, tz)

    DateTime.compare(event.start_at, day_end) == :lt and
      DateTime.compare(event.end_at, day_start) == :gt
  end
end
