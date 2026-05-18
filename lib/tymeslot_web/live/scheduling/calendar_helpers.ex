defmodule TymeslotWeb.Live.Scheduling.CalendarHelpers do
  @moduledoc """
  Calendar grid rendering and month/week navigation for the scheduling
  flow.

  Owns the data the schedule view binds against (calendar days, week
  days, slot DateTimes) plus the navigation handlers that move the
  visible window and trigger a re-fetch when the month changes.
  """

  alias Phoenix.Component
  alias Tymeslot.Availability.{BusinessHours, Calculate}
  alias Tymeslot.Demo
  alias Tymeslot.Timezones
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
  @spec get_calendar_days(String.t(), integer(), integer(), map() | nil, map() | atom() | nil) ::
          [map()]
  def get_calendar_days(user_timezone, year, month, organizer_profile, availability_map \\ nil) do
    if organizer_profile do
      if demo_user?(organizer_profile) do
        # Delegate to demo provider for calendar days
        Demo.get_calendar_days(user_timezone, year, month, organizer_profile, availability_map)
      else
        config = %{
          profile_id: organizer_profile.id,
          max_advance_booking_days: organizer_profile.advance_booking_days,
          min_advance_hours: organizer_profile.min_advance_hours,
          buffer_minutes: organizer_profile.buffer_minutes,
          owner_timezone: organizer_profile.timezone
        }

        Calculate.get_calendar_days(user_timezone, year, month, config, availability_map)
      end
    else
      # Return empty calendar days when profile is nil
      []
    end
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
  @spec get_week_days(Date.t(), map(), map() | atom() | nil, String.t()) :: [map()]
  def get_week_days(
        week_start,
        organizer_profile,
        availability_map \\ nil,
        user_timezone \\ "Etc/UTC"
      ) do
    if organizer_profile do
      today = user_timezone |> DateTimeUtils.now_in_timezone() |> DateTime.to_date()

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
              {day_available?(date, organizer_profile, today), false}
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
  Handles previous month navigation.
  """
  @spec handle_prev_month(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_prev_month(socket) do
    current_month = socket.assigns.current_month
    current_year = socket.assigns.current_year

    {prev_year, prev_month} =
      if current_month == 1, do: {current_year - 1, 12}, else: {current_year, current_month - 1}

    socket
    |> assign(:current_month, prev_month)
    |> assign(:current_year, prev_year)
    |> update_calendar_data()
  end

  @doc """
  Handles next month navigation.
  """
  @spec handle_next_month(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_next_month(socket) do
    current_month = socket.assigns.current_month
    current_year = socket.assigns.current_year

    {next_year, next_month} =
      if current_month == 12, do: {current_year + 1, 1}, else: {current_year, current_month + 1}

    socket
    |> assign(:current_month, next_month)
    |> assign(:current_year, next_year)
    |> update_calendar_data()
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
  Handles timezone change.
  """
  @spec handle_timezone_change(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_timezone_change(socket, timezone) do
    socket
    |> assign(:user_timezone, timezone)
    |> update_calendar_data()
  end

  @doc """
  Handles timezone search.
  """
  @spec handle_timezone_search(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_timezone_search(socket, search_term) do
    filtered_timezones = Timezones.search(search_term)
    assign(socket, :filtered_timezones, filtered_timezones)
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

  defp day_available?(date, organizer_profile, today) do
    is_weekday = BusinessHours.business_day?(date, organizer_profile.id)
    is_future = Date.compare(date, today) != :lt
    is_within_limit = Date.diff(date, today) <= organizer_profile.advance_booking_days

    is_weekday && is_future && is_within_limit
  end

  defp demo_user?(profile), do: Demo.demo_profile?(profile)

  defp update_calendar_data(socket) do
    %{
      current_month: current_month,
      current_year: current_year,
      user_timezone: user_timezone,
      organizer_profile: organizer_profile
    } = socket.assigns

    # Use availability map if present, otherwise nil (will use business hours only)
    availability_map = Map.get(socket.assigns, :month_availability_map)

    calendar_days =
      get_calendar_days(
        user_timezone,
        current_year,
        current_month,
        organizer_profile,
        availability_map
      )

    assign(socket, :calendar_days, calendar_days)
  end
end
