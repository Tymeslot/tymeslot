defmodule Tymeslot.Integrations.Calendar.CalendarEventQueries do
  @moduledoc """
  Queries that return canonical `CalendarEvent` structs.

  Wraps cache-level queries and converts results via
  `ProviderCalendarEventSchema.to_calendar_event/1`, so callers work with
  domain structs rather than database records.
  """

  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  @doc """
  Returns all cached events for the given integration IDs that overlap the range.

  Accepts either a `{DateTime, DateTime}` or `{Date, Date}` range tuple.
  Both timed and all-day events are checked for overlap.

  Returns a list of `CalendarEvent` structs.
  """
  @spec in_range([integer()], {DateTime.t(), DateTime.t()} | {Date.t(), Date.t()}) ::
          [CalendarEvent.t()]
  def in_range([], _range), do: []

  def in_range(integration_ids, {%DateTime{} = range_start, %DateTime{} = range_end}) do
    range_start_date = DateTime.to_date(range_start)
    range_end_date = DateTime.to_date(range_end)

    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id in ^integration_ids)
    |> where(
      [e],
      (e.all_day == false and e.start_at < ^range_end and e.end_at > ^range_start) or
        (e.all_day == true and e.start_date < ^range_end_date and e.end_date > ^range_start_date)
    )
    |> Repo.all()
    |> Enum.map(&ProviderCalendarEventSchema.to_calendar_event/1)
  end

  def in_range(integration_ids, {%Date{} = range_start, %Date{} = range_end}) do
    range_start_dt = DateTime.new!(range_start, ~T[00:00:00], "Etc/UTC")
    range_end_dt = DateTime.new!(Date.add(range_end, 1), ~T[00:00:00], "Etc/UTC")

    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id in ^integration_ids)
    |> where(
      [e],
      (e.all_day == false and e.start_at < ^range_end_dt and e.end_at > ^range_start_dt) or
        (e.all_day == true and e.start_date < ^range_end and e.end_date > ^range_start)
    )
    |> Repo.all()
    |> Enum.map(&ProviderCalendarEventSchema.to_calendar_event/1)
  end
end
