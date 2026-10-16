defmodule Tymeslot.CalendarGrid.EventWindow do
  @moduledoc """
  The events a calendar surface shows for a span of days: the cached provider
  events the organiser's calendar selection keeps, plus their Tymeslot
  bookings, less what they have hidden.

  Both calendar surfaces load through here (the old grid through
  `TymeslotWeb.Dashboard.CalendarGrid.Helpers.DataLoading`, the redesigned one
  through `TymeslotWeb.Dashboard.Calendar.SurfaceData`), so the two cannot
  disagree on what a week holds.
  """

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Selection

  @doc """
  The UTC instant `date` begins in `tz`. A zone that moves its clocks at
  midnight has no 00:00 on that date (the day starts at 01:00), or two of
  them; the day starts at the first instant either way.
  """
  @spec local_midnight(Date.t(), String.t()) :: DateTime.t()
  def local_midnight(date, tz) do
    instant =
      case DateTime.new(date, ~T[00:00:00], tz) do
        {:ok, midnight} -> midnight
        {:gap, _before, day_start} -> day_start
        {:ambiguous, first, _second} -> first
      end

    DateTime.shift_zone!(instant, "Etc/UTC")
  end

  @doc "From local midnight of `first` to local midnight after `last`, in UTC."
  @spec utc_range(Date.t(), Date.t(), String.t()) :: {DateTime.t(), DateTime.t()}
  def utc_range(first, last, tz),
    do: {local_midnight(first, tz), local_midnight(Date.add(last, 1), tz)}

  @doc """
  The events overlapping `[start_dt, end_dt)` for `user_id`: cached provider
  events from `integrations` that the calendar selection keeps, followed by
  the user's bookings that have no synced copy among them.

  Bookings are deduplicated against every cached row, not only the visible
  ones: a booking whose synced copy sits on a deselected calendar must stay
  out rather than reappear through its projection.
  """
  @spec list_events(pos_integer(), [map()], DateTime.t(), DateTime.t()) :: [map()]
  def list_events(user_id, integrations, start_dt, end_dt) do
    cached =
      integrations
      |> Enum.map(& &1.id)
      |> CalendarGrid.list_events_for_range(start_dt, end_dt)

    bookings = CalendarGrid.list_booking_events_for_range(user_id, start_dt, end_dt, cached)

    Selection.visible_events(cached, integrations) ++ bookings
  end

  @doc """
  Drops the events the organiser has hidden: a whole account by its id in
  `hidden_ids`, or one calendar by its `{integration_id, provider_calendar_id}`
  in `hidden_keys`. The two are separate stores and both are consulted, so
  hiding an account never erases the per-calendar choices underneath it.
  """
  @spec reject_hidden([map()], [integer()], MapSet.t()) :: [map()]
  def reject_hidden(events, hidden_ids, hidden_keys) do
    if hidden_ids == [] and MapSet.size(hidden_keys) == 0,
      do: events,
      else: Enum.reject(events, &hidden?(&1, hidden_ids, hidden_keys))
  end

  defp hidden?(event, hidden_ids, hidden_keys) do
    integration_id = Map.get(event, :calendar_integration_id)

    integration_id in hidden_ids or
      MapSet.member?(hidden_keys, {integration_id, Map.get(event, :provider_calendar_id)})
  end
end
