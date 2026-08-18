defmodule TymeslotWeb.Live.Scheduling.CalendarHelpers do
  @moduledoc """
  Calendar grid rendering and month/week navigation for the scheduling
  flow.

  Owns the data the schedule view binds against (calendar days, week
  days, slot DateTimes) plus the navigation handlers that move the
  visible window and trigger a re-fetch when the month changes.
  """

  alias Phoenix.Component
  alias Tymeslot.Availability.{BusinessHours, Calculate, Schedules}
  alias Tymeslot.Demo
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  import Component, only: [assign: 3]

  @doc """
  Gets calendar days for month view.

  ## Parameters
    - user_timezone: Timezone of the user viewing
    - year: Year to display
    - month: Month to display (1-12)
    - organizer_profile: Profile with booking settings
    - availability_map: Optional real availability data. Can be:
      - nil: Use business hours only (fast)
      - :loading: Show loading state
      - %{}: Use real conflict-aware availability
  """
  @spec get_calendar_days(
          String.t(),
          integer(),
          integer(),
          map() | nil,
          map() | atom() | nil,
          map() | nil
        ) :: [map()]
  def get_calendar_days(
        user_timezone,
        year,
        month,
        organizer_profile,
        availability_map \\ nil,
        meeting_type \\ nil
      ) do
    if organizer_profile do
      if Demo.demo_profile?(organizer_profile) do
        # Delegate to demo provider for calendar days
        Demo.get_calendar_days(user_timezone, year, month, organizer_profile, availability_map)
      else
        schedule = Schedules.resolve_for(meeting_type, organizer_profile)

        config = %{
          schedule_id: schedule && schedule.id,
          max_advance_booking_days: Schedules.policy(schedule, :advance_booking_days),
          min_advance_hours: Schedules.policy(schedule, :min_advance_hours),
          buffer_minutes: Schedules.policy(schedule, :buffer_minutes),
          owner_timezone: organizer_profile.timezone
        }

        Calculate.get_calendar_days(user_timezone, year, month, config, availability_map)
      end
    else
      # Return empty calendar days when profile is nil
      []
    end
    |> trim_trailing_other_month_weeks()
  end

  @doc """
  Drops trailing calendar weeks made up entirely of adjacent-month days.

  The underlying grid is a fixed 6 weeks, which for shorter months ends in a row
  that is *all* next-month — greyed out and never bookable. Removing such trailing
  rows shortens the calendar by up to a week so it fits more viewports without an
  internal scroll. Any week containing a current-month day is always kept, so the
  current month is never truncated.
  """
  @spec trim_trailing_other_month_weeks([map()]) :: [map()]
  def trim_trailing_other_month_weeks([]), do: []

  def trim_trailing_other_month_weeks(days) do
    days
    |> Enum.chunk_every(7)
    |> Enum.reverse()
    |> Enum.drop_while(fn week ->
      Enum.all?(week, &(not Map.get(&1, :current_month, false)))
    end)
    |> Enum.reverse()
    |> Enum.concat()
  end

  @doc """
  Computes the 42-day display range for a calendar grid.

  Delegates to `Calculate.display_range/2` — the single source of truth
  for the calendar grid window.
  """
  @spec display_range(integer(), integer()) :: {Date.t(), Date.t()}
  defdelegate display_range(year, month), to: Calculate

  @doc """
  Gets calendar days for a week view.
  """
  @spec get_week_days(Date.t(), map(), map() | atom() | nil, String.t(), map() | nil) :: [map()]
  def get_week_days(
        week_start,
        organizer_profile,
        availability_map \\ nil,
        user_timezone \\ "Etc/UTC",
        meeting_type \\ nil
      ) do
    if organizer_profile do
      today = user_timezone |> DateTimeUtils.now_in_timezone() |> DateTime.to_date()

      # Resolved once rather than inside the loop: the fallback branch below runs
      # for all seven days and would otherwise repeat the same lookup each time.
      schedule = fallback_schedule(organizer_profile, availability_map, meeting_type)
      schedule_data = prefetched_schedule_data(schedule, week_start)

      Enum.map(0..6, fn day_offset ->
        date = Date.add(week_start, day_offset)
        date_string = Date.to_string(date)

        {is_available, is_loading} =
          cond do
            availability_map == :loading ->
              {false, true}

            is_map(availability_map) ->
              {Map.get(availability_map, date_string, false), false}

            true ->
              {day_available?(date, schedule, schedule_data, today), false}
          end

        %{
          date: date_string,
          day_name: LocalizationHelpers.day_name_short(Date.day_of_week(date)),
          day_number: date.day,
          available: is_available,
          loading: is_loading,
          today: date == today
        }
      end)
    else
      []
    end
  end

  @doc """
  Handles week navigation (prev/next).

  Advances `current_week_start` by ±7 days. When the week crosses a month
  boundary, also updates month/year assigns and refetches availability.
  """
  @spec handle_week_navigation(Phoenix.LiveView.Socket.t(), :prev | :next) ::
          Phoenix.LiveView.Socket.t()
  def handle_week_navigation(socket, direction) do
    offset = if direction == :next, do: 7, else: -7
    new_week_start = Date.add(socket.assigns.current_week_start, offset)

    # Use the middle of the week as a reference for which month's availability to fetch
    reference_date = Date.add(new_week_start, 3)

    if socket.assigns.current_month != reference_date.month or
         socket.assigns.current_year != reference_date.year do
      socket
      |> assign(:current_week_start, new_week_start)
      |> assign(:current_month, reference_date.month)
      |> assign(:current_year, reference_date.year)
      |> assign(:month_availability_map, nil)
      |> assign(:availability_status, :not_loaded)
      |> AvailabilityHelpers.fetch_month_availability_async()
    else
      assign(socket, :current_week_start, new_week_start)
    end
  end

  @doc """
  Parses slot time string to DateTime for display.
  """
  @spec parse_slot_time(String.t()) :: DateTime.t()
  def parse_slot_time(slot_string) do
    case DateTimeUtils.parse_time_string(slot_string) do
      {:ok, time} ->
        {:ok, dt} = DateTime.new(Date.utc_today(), time)
        dt

      {:error, _reason} ->
        DateTime.utc_now()
    end
  end

  # Only the fallback path needs a schedule; a supplied availability map already
  # answers the question, so resolving one there would be a pointless query.
  defp fallback_schedule(_organizer_profile, :loading, _meeting_type), do: nil

  defp fallback_schedule(organizer_profile, availability_map, meeting_type) do
    if is_map(availability_map) do
      nil
    else
      Schedules.resolve_for(meeting_type, organizer_profile)
    end
  end

  # This runs inside the template render of a public page, so the seven
  # per-day business-hours lookups must not each hit the database.
  defp prefetched_schedule_data(nil, _week_start), do: %{}

  defp prefetched_schedule_data(schedule, week_start) do
    Calculate.prefetch_schedule_data(
      %{},
      schedule.id,
      Date.add(week_start, -1),
      Date.add(week_start, 7)
    )
  end

  defp day_available?(date, schedule, schedule_data, today) do
    is_weekday = BusinessHours.business_day?(date, schedule && schedule.id, schedule_data)
    is_future = Date.compare(date, today) != :lt
    is_within_limit = Date.diff(date, today) <= Schedules.policy(schedule, :advance_booking_days)

    is_weekday && is_future && is_within_limit
  end
end
