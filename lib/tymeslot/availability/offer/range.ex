defmodule Tymeslot.Availability.Offer.Range do
  @moduledoc false
  # The range half of `Tymeslot.Availability.Offer`: the starts and offered
  # times for every day of a range (`Offer.starts_in_range/5`,
  # `Offer.slots_for_range/4`), with everything that does not depend on the
  # day read once for the whole range.

  alias Tymeslot.Availability.Bookability
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.Offer
  alias Tymeslot.Availability.Offer.Request
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.MeetingTypes.FixedDates

  # The longest range `Offer.slots_for_range/4` answers: six weeks, the month
  # grid's display range. A week view asks for seven days; the bound keeps a
  # caller's mistake from computing a year of slots.
  @max_range_days 42

  # Read by `Offer`'s docs.
  @spec max_range_days() :: pos_integer()
  def max_range_days, do: @max_range_days

  # See `Tymeslot.Availability.Offer.starts_in_range/5`.
  @spec starts_in_range(
          Offer.request(),
          Date.t(),
          Date.t(),
          String.t() | integer() | nil,
          keyword()
        ) ::
          {:ok, %{Date.t() => [DateTime.t()]}} | {:error, any()}
  def starts_in_range(request, %Date{} = start_date, %Date{} = end_date, duration, opts) do
    with :ok <- check_range(start_date, end_date) do
      if FixedDates.enabled?(request[:meeting_type]) do
        # A fixed-date type offers only the sessions its host planned, which
        # are joined, never started: no new meeting fits anywhere.
        {:ok, Map.new(Date.range(start_date, end_date), &{&1, []})}
      else
        with {:ok, %{starts: starts}} <-
               range_starts(request, start_date, end_date, duration, opts[:events] || :fresh),
             do: {:ok, starts}
      end
    end
  end

  # `{:error, :invalid_range}` for a range that ends before it starts,
  # `{:error, :range_too_long}` for one longer than `@max_range_days`.
  @spec check_range(Date.t(), Date.t()) :: :ok | {:error, :invalid_range | :range_too_long}
  def check_range(start_date, end_date) do
    cond do
      Date.compare(start_date, end_date) == :gt -> {:error, :invalid_range}
      Date.diff(end_date, start_date) >= @max_range_days -> {:error, :range_too_long}
      true -> :ok
    end
  end

  # `Offer.slots_for_date/3` for every day of a range, labelled from
  # `range_starts/5`. Everything that does not depend on the day read once:
  # the calendar (whose fetch covers the whole booking window whatever date
  # it is given), the proven reschedule meeting, the booking-limit counts
  # over the range, and the schedule's weekly hours, overrides and time off
  # for the range and a day either side, which
  # `Calculate.available_starts/6` then finds already in the config. The busy
  # set is merged over the range, so each day sees every booking and event
  # that a single date's read would merge for it alone.
  @spec free_slots_in_range(Offer.request(), Date.t(), Date.t(), String.t() | integer() | nil) ::
          {:ok, %{String.t() => [term()]}} | {:error, any()}
  def free_slots_in_range(request, start_date, end_date, duration) do
    with {:ok, %{starts: starts, context: context}} <-
           range_starts(request, start_date, end_date, duration, :fresh) do
      {:ok,
       Map.new(starts, fn {date, day_starts} ->
         {Date.to_iso8601(date),
          Request.offered_slots(day_starts, request[:meeting_type], date, context)}
       end)}
    end
  end

  # The engine's starts for every day of the range, keyed by date, with the
  # busy set and config they were computed against (a group type's seat
  # overlay needs both). `:fresh` asks the calendar; `:cached` is the
  # booking-window read the day and month views use.
  defp range_starts(
         %{profile: %{user_id: user_id} = profile} = request,
         start_date,
         end_date,
         duration,
         events_source
       ) do
    moving = Request.moving_meeting(request)

    with {:ok, events} <- range_events(request, {start_date, end_date}, events_source) do
      duration_minutes = Request.bounded_duration(duration)
      meeting_type = request[:meeting_type]

      limit_checker =
        Request.limit_checker(request, Request.moving_uid(moving), start_date, end_date)

      config =
        meeting_type
        |> Schedules.resolve_for(profile)
        |> Request.config(meeting_type, limit_checker, duration_minutes)

      config =
        Calculate.prefetch_schedule_data(
          config,
          config.schedule_id,
          Date.add(start_date, -1),
          Date.add(end_date, 1)
        )

      busy = Request.busy_periods(events, user_id, start_date, end_date, moving)

      day_starts = fn date ->
        Calculate.available_starts(
          date,
          duration_minutes,
          request.user_timezone,
          Request.owner_timezone(profile),
          busy,
          config
        )
      end

      with {:ok, starts} <- collect_days(start_date, end_date, day_starts, & &1) do
        {:ok,
         %{
           starts: starts,
           context: %{
             user_timezone: request.user_timezone,
             owner_timezone: Request.owner_timezone(profile),
             events: busy,
             config: config
           }
         }}
      end
    end
  end

  # The fresh read gets the bookability rule the cached one is stored with.
  defp range_events(
         %{profile: %{user_id: user_id}} = request,
         {start_date, _end_date} = dates,
         :fresh
       ) do
    with {:ok, events} <-
           CalendarEvents.get_calendar_events_from_context(
             start_date,
             user_id,
             Request.calendar_context(request)
           ) do
      {:ok, Bookability.apply_to_dates(events, user_id, dates)}
    end
  end

  defp range_events(request, {start_date, _end_date}, :cached),
    do: Request.booking_window_events(request, start_date)

  # `day_result` for every day of the range, keyed by `key.(date)`; the first
  # day that fails fails the range.
  @spec collect_days(
          Date.t(),
          Date.t(),
          (Date.t() -> {:ok, term()} | {:error, any()}),
          (Date.t() -> term())
        ) ::
          {:ok, map()} | {:error, any()}
  def collect_days(start_date, end_date, day_result, key \\ &Date.to_iso8601/1) do
    start_date
    |> Date.range(end_date)
    |> Enum.reduce_while({:ok, %{}}, fn date, {:ok, acc} ->
      case day_result.(date) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key.(date), value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
