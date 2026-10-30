defmodule TymeslotWeb.Live.Scheduling.CalendarDays do
  @moduledoc """
  The day data the scheduling flow's calendars render: the month grid
  (`get_calendar_days/7`, trailing weeks wholly in the next month trimmed by
  `trim_trailing_other_month_weeks/1`) and the week strip (`get_week_days/5`).

  Both answer which days are bookable from the real availability map when
  one is loaded, and otherwise from the host's business hours on the same
  `availability_config` the domain uses, so the grid and the strip never
  disagree. Demo profiles answer from the demo provider instead. Positioning
  the calendar and navigating it live in `CalendarHelpers`.
  """

  alias Tymeslot.Availability.{Calculate, Offer, Schedules}
  alias Tymeslot.Demo
  alias Tymeslot.Profiles
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @doc """
  Gets calendar days for month view.

  ## Parameters
    - user_timezone: Timezone of the user viewing
    - year: Year to display
    - month: Month to display (1-12)
    - week_start: `:monday` or `:sunday`, the grid's first column
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
          :monday | :sunday,
          map() | nil,
          map() | atom() | nil,
          map() | nil
        ) :: [map()]
  def get_calendar_days(
        user_timezone,
        year,
        month,
        week_start,
        organizer_profile,
        availability_map,
        meeting_type \\ nil
      ) do
    if organizer_profile do
      if Demo.demo_profile?(organizer_profile) do
        # Delegate to demo provider for calendar days
        Demo.get_calendar_days(
          user_timezone,
          year,
          month,
          week_start,
          organizer_profile,
          availability_map
        )
      else
        schedule = Schedules.resolve_for(meeting_type, organizer_profile)
        config = availability_config(schedule, organizer_profile, meeting_type)

        Calculate.get_calendar_days(
          user_timezone,
          year,
          month,
          week_start,
          config,
          availability_map
        )
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
  Gets calendar days for a week view.
  """
  @spec get_week_days(Date.t(), map(), map() | atom() | nil, String.t(), map() | nil) :: [map()]
  def get_week_days(
        week_start,
        organizer_profile,
        availability_map,
        user_timezone,
        meeting_type \\ nil
      ) do
    if organizer_profile do
      today = CalendarHelpers.visitor_today(user_timezone)

      day_availability =
        day_availability_lookup(
          week_start,
          organizer_profile,
          availability_map,
          user_timezone,
          meeting_type
        )

      Enum.map(0..6, fn day_offset ->
        date = Date.add(week_start, day_offset)
        date_string = Date.to_string(date)

        {is_available, is_loading} = day_availability.(date, date_string)

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

  # Resolved once rather than inside the loop: each branch is loop-invariant
  # across the seven days, and building a closure here means only the branch
  # actually taken pays its cost (a demo grid fetch or a schedule prefetch)
  # instead of both running and one being discarded on every render.
  defp day_availability_lookup(
         week_start,
         organizer_profile,
         availability_map,
         user_timezone,
         meeting_type
       ) do
    cond do
      availability_map == :loading ->
        fn _date, _date_string -> {false, true} end

      is_map(availability_map) ->
        uncovered =
          uncovered_lookup(
            week_start,
            organizer_profile,
            availability_map,
            user_timezone,
            meeting_type
          )

        fn date, date_string ->
          case Map.fetch(availability_map, date_string) do
            {:ok, available} -> {available, false}
            :error -> uncovered.(date, date_string)
          end
        end

      Demo.demo_profile?(organizer_profile) ->
        # Demo profiles answer the fallback question with the same demo
        # generator the month grid uses, not Core's hard-coded business
        # hours. Should the provider's generator have no days for a profile
        # it calls a demo one, fall back to business hours rather than
        # render every day of the week as unavailable.
        demo_days =
          demo_calendar_days(week_start, organizer_profile, availability_map, user_timezone)

        if demo_days == %{} do
          business_hours_lookup(
            week_start,
            organizer_profile,
            availability_map,
            meeting_type,
            user_timezone
          )
        else
          fn _date, date_string -> {Map.get(demo_days, date_string, false), false} end
        end

      true ->
        business_hours_lookup(
          week_start,
          organizer_profile,
          availability_map,
          meeting_type,
          user_timezone
        )
    end
  end

  # A day the map does not carry is *unknown*, not unavailable.
  #
  # The map is folded over `Calculate.display_range/3` — a 42-day block
  # around a month — while the strip renders a week. Both are anchored on
  # the same `:week_start`, so a week touching the loaded month sits inside
  # the block, whether the arrows moved it there (`handle_week_navigation/2`
  # refetches whenever they move the week's midpoint into another month) or
  # `anchor_on/2` positioned it from a date. A day the map still lacks is
  # answered below rather than guessed.
  #
  # Reading the absent day as `false` painted it exactly like a fully booked
  # one — greyed out and unclickable — on the strength of a question nobody
  # asked the calendar. Both strips do it: Rhythm's week view and Quill's
  # narrow-screen weekly row disable the button on the same value.
  #
  # An uncovered day is instead answered the way the strip answers when there
  # is no map at all: the host's business hours, which is the same domain rule
  # the month grid falls back to, and clicking the day fetches its real slots.
  # The worst case becomes a day that turns out to be full, rather than a
  # bookable day the booker can never reach. Resolved once, and only when the
  # week actually has a gap, so a fully covered week pays nothing for it —
  # the fallback costs a schedule lookup and a prefetch.
  defp uncovered_lookup(
         week_start,
         organizer_profile,
         availability_map,
         user_timezone,
         meeting_type
       ) do
    if week_covered?(week_start, availability_map) do
      fn _date, _date_string -> {false, false} end
    else
      day_availability_lookup(week_start, organizer_profile, nil, user_timezone, meeting_type)
    end
  end

  defp week_covered?(week_start, availability_map) do
    Enum.all?(0..6, fn offset ->
      Map.has_key?(availability_map, week_start |> Date.add(offset) |> Date.to_string())
    end)
  end

  defp business_hours_lookup(
         week_start,
         organizer_profile,
         availability_map,
         meeting_type,
         user_timezone
       ) do
    schedule = fallback_schedule(organizer_profile, availability_map, meeting_type)
    fallback_config = fallback_config(schedule, organizer_profile, week_start, meeting_type)

    fn date, _date_string ->
      {Calculate.day_bookable_by_business_hours?(date, user_timezone, fallback_config), false}
    end
  end

  # A week can straddle a month boundary, so build the lookup from every
  # month it touches rather than assuming `week_start`'s month covers it.
  # Each month's grid holds all of that month's days whichever weekday it
  # starts on, so the grid's own anchoring is immaterial here.
  defp demo_calendar_days(week_start, organizer_profile, availability_map, user_timezone) do
    0..6
    |> Enum.map(&Date.add(week_start, &1))
    |> Enum.map(&{&1.year, &1.month})
    |> Enum.uniq()
    |> Enum.flat_map(fn {year, month} ->
      Demo.get_calendar_days(
        user_timezone,
        year,
        month,
        :monday,
        organizer_profile,
        availability_map
      )
    end)
    |> Map.new(&{&1.date, &1.available})
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

  # The same config the month grid builds, so the week strip answers the
  # availability question with the domain's rule rather than a second copy of
  # it. Prefetched because this runs inside the template render of a public
  # page: without it the seven per-day business-hours lookups each hit the
  # database.
  defp fallback_config(schedule, organizer_profile, week_start, meeting_type) do
    config = availability_config(schedule, organizer_profile, meeting_type)

    Calculate.prefetch_schedule_data(
      config,
      schedule && schedule.id,
      Date.add(week_start, -1),
      Date.add(week_start, 7)
    )
  end

  # The month grid and the week strip fallback answer the same availability
  # question, so both build their `availability_config` from this single
  # place, on the scheduling rules `Schedules.config/2` assembles for the real
  # availability path and the booking submit alike.
  #
  # `owner_timezone` is read through `Profiles.timezone/1`, as everywhere an
  # owner's clock is read, so a nil profile timezone resolves to the same zone
  # here as on the real availability path.
  @spec availability_config(map() | nil, map(), map() | nil) :: %{
          required(:schedule_id) => integer() | nil,
          required(:max_advance_booking_days) => pos_integer(),
          required(:min_advance_hours) => non_neg_integer(),
          required(:buffer_before_minutes) => non_neg_integer(),
          required(:buffer_after_minutes) => non_neg_integer(),
          required(:slot_interval_minutes) => pos_integer() | nil,
          required(:duration_minutes) => pos_integer(),
          required(:owner_timezone) => String.t()
        }
  defp availability_config(schedule, organizer_profile, meeting_type) do
    schedule
    |> Schedules.config(meeting_type)
    |> Map.merge(%{
      duration_minutes: Offer.duration_minutes(meeting_type, nil),
      owner_timezone: Profiles.timezone(organizer_profile)
    })
  end
end
