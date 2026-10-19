defmodule TymeslotWeb.Live.Scheduling.CalendarHelpers do
  @moduledoc """
  Calendar grid rendering and navigation for the scheduling flow.

  Provides the calendar and week day data the schedule view templates render
  directly; positions the calendar on a date (`anchor_on/2`, the one place the
  month and week are set from a date), on the booker's today
  (`anchor_on_today/1`) or on the day they have chosen
  (`anchor_on_selection/1`), or on a day on the booker's behalf (`land_on/2`),
  can tell whether the calendar is still where the page left it
  (`untouched?/1`), and which week it landed the booker on (`landing_week/1`),
  and move back there (`return_to_landing/1`); and handles week and month navigation, which move the
  visible window and refetch availability when the month changes.
  """

  alias Phoenix.Component
  alias Tymeslot.Availability.{Calculate, Offer, Schedules}
  alias Tymeslot.Demo
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  import Component, only: [assign: 2, assign: 3]

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
      today = visitor_today(user_timezone)

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

  @doc """
  Opens the calendar on the booker's today: the month and the week that
  contain it, in `:user_timezone`, the week starting on `:week_start`.

  Also records the date as `:calendar_today`, and this position, with no day
  selected, as where the page left the calendar (see `untouched?/1`). Reads
  the time through `Tymeslot.Clock`.
  """
  @spec anchor_on_today(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def anchor_on_today(socket) do
    today = today_for(socket.assigns)

    socket
    |> assign(:calendar_today, today)
    |> anchor_on(today)
    |> assign(
      :calendar_landing,
      Map.put(calendar_window(today, socket.assigns.week_start), :selected_date, nil)
    )
  end

  @doc """
  Moves the calendar onto `date` on the booker's behalf, like `anchor_on/2`,
  and records the result, with whatever day is selected, as where the page
  left the calendar.

  For the positions the page chooses itself: `NextAvailable` landing on the
  first free day, or stepping forward to look for one. A position the booker
  chose (a click, a `?date=` link) goes through `anchor_on/2`, so it never
  counts as the page's.
  """
  @spec land_on(Phoenix.LiveView.Socket.t(), Date.t()) :: Phoenix.LiveView.Socket.t()
  def land_on(socket, %Date{} = date) do
    socket = anchor_on(socket, date)
    assign(socket, :calendar_landing, calendar_position(socket.assigns))
  end

  @doc """
  Whether the calendar is still where the page left it: the day selected, the
  month and the week are exactly the ones `anchor_on_today/1` or `land_on/2`
  last set.

  Anything the booker does moves one of them: a click selects another day, a
  `?date=` link selects one the page did not, and the arrows move the month or
  the week. A booker who clicks the very day the page picked for them leaves it
  untouched; the page's choice and theirs agree, so nothing is lost by either
  reading.
  """
  @spec untouched?(map()) :: boolean()
  def untouched?(assigns) do
    case assigns[:calendar_landing] do
      %{} = landing -> landing == calendar_position(assigns)
      _never_placed -> false
    end
  end

  defp calendar_position(assigns) do
    assigns
    |> Map.take([:current_year, :current_month, :current_week_start])
    |> Map.put(:selected_date, blank_to_nil(assigns[:selected_date]))
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @doc """
  The week the page landed the booker on when it picked their first free day
  (`land_on/2`, from `NextAvailable`), or nil when it landed on no day: before
  the month's availability arrives, when no day was free, or when the booker
  had chosen one already (a `?date=` link, an earlier visit).
  """
  @spec landing_week(map()) :: Date.t() | nil
  def landing_week(%{calendar_landing: %{selected_date: day, current_week_start: %Date{} = week}})
      when is_binary(day) and day != "",
      do: week

  def landing_week(_assigns), do: nil

  @doc """
  Moves the month and the week back to where the page landed the booker
  (`landing_week/1`), leaving the selected day and time as they are; a no-op
  when it landed on no day. A move into another month drops the month's
  availability and fetches it, as week navigation does.
  """
  @spec return_to_landing(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def return_to_landing(socket) do
    case landing_week(socket.assigns) do
      nil ->
        socket

      week ->
        %{current_year: year, current_month: month} = socket.assigns.calendar_landing

        moved_month? =
          {year, month} != {socket.assigns[:current_year], socket.assigns[:current_month]}

        socket =
          assign(socket, current_year: year, current_month: month, current_week_start: week)

        if moved_month? do
          socket
          |> assign(month_availability_map: nil, availability_status: :not_loaded)
          |> AvailabilityHelpers.fetch_month_availability_async()
        else
          socket
        end
    end
  end

  @doc """
  Moves the calendar onto `date`: its month, and the week that contains it,
  starting on the socket's `:week_start` (`:monday` or `:sunday`).

  Every code path that positions the calendar on a date goes through here
  (today, a chosen or linked day, the day `NextAvailable` lands on), so the
  month grid and the week strips can never disagree about where they are.
  """
  @spec anchor_on(Phoenix.LiveView.Socket.t(), Date.t()) :: Phoenix.LiveView.Socket.t()
  def anchor_on(socket, %Date{} = date),
    do: assign(socket, calendar_window(date, socket.assigns.week_start))

  defp calendar_window(date, week_start) do
    %{
      current_year: date.year,
      current_month: date.month,
      current_week_start: Date.beginning_of_week(date, week_start)
    }
  end

  @doc """
  Opens the calendar for an arrival at the schedule step.

  A chosen day, whether linked (`?date=`) or left by an earlier visit to the
  step, opens its own month and week when the booker can book it: from today
  to the last day of `:booking_window_days`, both inclusive, in
  `:user_timezone`. These are the bounds `Availability.Calculate` greys days
  out by. A day outside them is dropped together with its time, so the calendar
  opens on today and `NextAvailable` lands the booker on a real day, instead
  of keeping a selection they can neither see nor book. With no day chosen this
  is `anchor_on_today/1`.
  """
  @spec anchor_on_selection(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def anchor_on_selection(socket) do
    socket = anchor_on_today(socket)
    %{calendar_today: today} = socket.assigns

    case chosen_day(socket.assigns[:selected_date], today, socket.assigns[:booking_window_days]) do
      {:bookable, date} -> anchor_on(socket, date)
      :none -> socket
      :out_of_window -> assign(socket, selected_date: nil, selected_time: nil)
    end
  end

  @doc """
  Whether the selected day lies outside the booking window as the booker's
  timezone, `:user_timezone`, now has it: before today there, or past the
  window's last day. The same bounds `anchor_on_selection/1` drops a day by.

  After a change of timezone a day the booker could book can be one they no
  longer can: their today moved on to the next date. No day selected is never
  outside the window.
  """
  @spec selection_out_of_window?(map()) :: boolean()
  def selection_out_of_window?(assigns) do
    chosen_day(assigns[:selected_date], today_for(assigns), assigns[:booking_window_days]) ==
      :out_of_window
  end

  defp today_for(assigns),
    do: visitor_today(assigns[:user_timezone] || Profiles.get_default_timezone())

  @doc """
  The date it is now in the visitor's `timezone`, read through `Tymeslot.Clock`
  so it stays freezable. Blocks that say "Today" compute it live from this,
  as the month calendar does, rather than reading the `:calendar_today` the
  page recorded earlier, which a change of timezone or midnight leaves stale.
  """
  @spec visitor_today(String.t()) :: Date.t()
  def visitor_today(timezone) do
    timezone
    |> DateTimeUtils.now_in_timezone()
    |> DateTime.to_date()
  end

  defp chosen_day(value, today, window_days) when is_binary(value) and value != "" do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        if within_window?(date, today, window_days), do: {:bookable, date}, else: :out_of_window

      {:error, _reason} ->
        :out_of_window
    end
  end

  defp chosen_day(_value, _today, _window_days), do: :none

  # No window assigned (no organiser resolved) bounds only the past; the
  # schedule step always has one.
  defp within_window?(date, today, window_days) do
    Date.compare(date, today) != :lt and
      (not is_integer(window_days) or Date.compare(date, Date.add(today, window_days)) != :gt)
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
  Handles month navigation (prev/next) for a calendar paged by month.

  Moves `current_year`/`current_month` one month, drops the day and time the
  booker picked (they belong to the month being left) along with that month's
  availability, and fetches the new month's.
  """
  @spec handle_month_navigation(Phoenix.LiveView.Socket.t(), :prev | :next) ::
          Phoenix.LiveView.Socket.t()
  def handle_month_navigation(socket, direction) do
    %Date{year: year, month: month} =
      socket.assigns.current_year
      |> Date.new!(socket.assigns.current_month, 1)
      |> Date.shift(month: if(direction == :next, do: 1, else: -1))

    socket
    |> assign(
      current_year: year,
      current_month: month,
      selected_date: nil,
      selected_time: nil,
      available_slots: [],
      month_availability_map: nil,
      availability_status: :not_loaded
    )
    |> AvailabilityHelpers.fetch_month_availability_async()
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
