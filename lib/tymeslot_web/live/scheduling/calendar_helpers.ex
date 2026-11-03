defmodule TymeslotWeb.Live.Scheduling.CalendarHelpers do
  @moduledoc """
  Calendar positioning and navigation for the scheduling flow.

  Positions the calendar on a date (`anchor_on/2`, the one place the month and
  week are set from a date), on the booker's today (`anchor_on_today/1`) or on
  the day they have chosen (`anchor_on_selection/1`), or on a day on the
  booker's behalf (`land_on/2`); can tell whether the calendar is still where
  the page left it (`untouched?/1`), and which week it landed the booker on
  (`landing_week/1`), and move back there (`return_to_landing/1`); and handles
  week and month navigation, which move the visible window and refetch
  availability when the month changes. The day data the calendars render is
  built by `CalendarDays`.
  """

  alias Phoenix.Component
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers

  import Component, only: [assign: 2, assign: 3]

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
end
