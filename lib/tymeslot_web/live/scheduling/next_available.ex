defmodule TymeslotWeb.Live.Scheduling.NextAvailable do
  @moduledoc """
  Lands the booker on the first bookable day instead of an empty grid.

  Entering the schedule step used to assign nothing but the current
  month: `selected_date` stayed `nil`, so the booker faced a month of
  greyed-out squares and had to hunt for a live one before a single time
  appeared. Where the host was fully booked for the rest of the month
  that hunt failed silently — the grid renders an all-disabled month
  exactly the same way it renders a month nobody has looked at yet, and
  nothing on screen suggests pressing "next month" would help.

  So the selection is made from the availability map the schedule step
  already fetches. `month_availability_map` is `%{"2026-01-15" => bool}`
  over the 42-day display range, which is the same data the grid paints
  from, so the day picked here is always a day the booker can see and
  click. No extra query buys the common case.

  Two boundaries decide the rest:

    * The map spans a *display* range, not a calendar month, so it
      carries days belonging to the neighbouring months. Selecting one
      without moving the visible window would highlight a day drawn as
      an adjacent-month square, or none at all — `align_to/2` moves the
      month and the week to wherever the chosen day actually lives.

    * When the whole range is dead the search steps forward a month at a
      time, bounded by the resolved booking window. That bound is the same
      one `CalendarNavigation.next_month_disabled?/4` uses to grey out the
      forward arrow, so this never lands on a month the booker could not
      have reached by hand.

  A date carried in on the URL (a shared link, a link back into a half-made
  booking) is a deliberate choice and is left untouched; `apply/1` only fills
  a blank selection. The schedule-step entry (`CalendarHelpers.anchor_on_selection/1`)
  has already opened the calendar on that day, or dropped it if it lies outside
  the booking window, so a day still selected here is one the booker can see
  and book.

  A reschedule gets the same landing as any other booking. It is the case that
  needs it most: a slot is being moved because the host's calendar was busy
  enough to require it, so the rescheduler faces the emptiest grid of anyone.

  The landing is attempted once per arrival at the step, and every terminal
  outcome spends the attempt — including the ones that select nothing. Leaving
  it armed is what turns a later refetch into a calendar that walks backwards;
  `settle/1` documents that failure in full.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers
  alias TymeslotWeb.Themes.Shared.Journey.Progress

  require Logger

  # Guards the forward search against a pathological advance window. A host
  # allowing bookings a year out whose calendar is empty would otherwise cost
  # twelve availability fetches on a single page load.
  @max_months_searched 3

  @doc """
  Selects the first available day and loads its slots.

  Returns `{socket, :done}` when the work is finished — a day was
  selected, the selection was left alone, or the search hit its bound —
  and `{socket, :refetch}` when the window has been moved forward and the
  caller must fetch availability for the new month.

  The refetch is handed back rather than performed here so this module
  keeps no dependency on the fetcher that calls it: `AvailabilityHelpers`
  already reaches `NextAvailable` through `InfoHandlers`, and calling
  back into it from here would close that loop into a cycle.
  """
  @spec apply(Phoenix.LiveView.Socket.t()) :: {Phoenix.LiveView.Socket.t(), :done | :refetch}
  def apply(socket) do
    cond do
      # Availability also loads before the booker reaches the moment that
      # collects the slot (the classic schedule step). That is not the
      # landing attempt, so it must not spend it.
      not Progress.collecting_now?(socket.assigns, :slot) -> {socket, :done}
      settled?(socket) -> {socket, :done}
      explicitly_chosen?(socket) -> {settle(socket), :done}
      true -> land(socket)
    end
  end

  defp land(socket) do
    case first_available_date(socket) do
      nil -> search_forward(socket)
      date -> {socket |> select(date) |> settle(), :done}
    end
  end

  @doc """
  Spends the landing attempt without selecting anything.

  Callers use this for the outcomes that never reach `apply/1`: a fetch that
  errored produces no map to search, but it was still the one chance to land,
  and treating it as a deferral is what leaves the calendar moving under the
  booker later.

  Every navigation control clears or bypasses `selected_date` and refetches —
  Quill's month arrows blank it outright, Rhythm's week arrows cross a month
  boundary, and a calendar-sync broadcast refetches with no input at all. Any
  of those, with the attempt still unspent, re-enters `apply/1` against the new
  month's map. That map spans a *display* range whose leading row belongs to
  the month just left, so the earliest free day in it is routinely a day
  behind the booker, and `align_to/2` then drags the visible window back onto
  it: press "next", travel backwards.

  A no-op before the moment collecting the slot (the classic schedule step), so a fetch that fails on the overview
  leaves the landing intact for the step that has not been reached yet.
  """
  @spec settle(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def settle(socket) do
    if Progress.collecting_now?(socket.assigns, :slot) do
      assign(socket, :auto_select_settled, true)
    else
      socket
    end
  end

  @doc """
  Re-arms the landing for a fresh entry into the schedule step.

  The attempt is spent per *entry*, not per LiveView. `do_handle_schedule_entry/2`
  reopens the calendar every time the booker arrives (on the chosen day's month
  and week, or today's), so a second arrival — back to the overview, a different
  duration, forward again — is a new landing and gets its own hop budget.
  Without the reset a search that spent its budget on a booked-out duration
  would silently disable itself for every duration chosen afterwards.
  """
  @spec reset(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset(socket) do
    socket
    |> assign(:auto_select_settled, false)
    |> assign(:auto_select_months_searched, 0)
  end

  defp settled?(socket), do: socket.assigns[:auto_select_settled] == true

  # An explicit selection always wins over a computed one, so a shared link
  # keeps the day it names rather than having it replaced by the earliest free
  # one. `handle_param_updates/2` seeds the URL date, and
  # `do_handle_schedule_entry/2` seeds it again for a step transition, whose
  # params never reach `handle_params/3`. A linked day outside the booking
  # window never gets this far: the schedule-step entry drops it.
  #
  # A date is the only thing that counts as chosen. A reschedule used to be
  # treated as one too, on the belief that its link carried a date; it does
  # not — `PathHandlers.organizer_scheduling_path/1` builds
  # `/:username?reschedule_meeting_uid=…` and nothing else — so the check only
  # ever switched the landing off for the people most in need of it.
  defp explicitly_chosen?(socket) do
    socket.assigns[:selected_date] not in [nil, ""]
  end

  @doc """
  Returns the earliest bookable date string in the loaded availability
  map, or `nil` when the map holds none.

  Days before today are dropped even when the map marks them available:
  the grid disables them unconditionally (`Calculate.determine_availability/6`
  short-circuits on the past), and selecting one would load slots for a
  day the booker cannot click.
  """
  @spec first_available_date(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def first_available_date(socket) do
    with map when is_map(map) <- socket.assigns[:month_availability_map],
         today <- today_for(socket) do
      map
      |> Enum.filter(fn {date_string, available} ->
        available == true and not past?(date_string, today)
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.min(fn -> nil end)
    else
      _not_loaded -> nil
    end
  end

  # Date strings are ISO-8601, so lexicographic order is chronological
  # order and the min/2 above needs no comparator.
  defp past?(date_string, today) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> Date.compare(date, today) == :lt
      _invalid -> true
    end
  end

  # Selects the chosen day, moves the visible window onto it, then asks for
  # its slots. `Journey.Facts.Slot`'s `select_date/2` does the same three things
  # on a click; this is that path without the click, so the two stay in step.
  defp select(socket, date_string) do
    socket
    |> assign(:selected_date, date_string)
    |> align_to(date_string)
    |> assign(:selected_time, nil)
    |> assign(:loading_slots, true)
    |> assign(:calendar_error, nil)
    |> tap(fn _socket -> send(self(), {:load_slots, date_string}) end)
  end

  # The month view keys off current_year/current_month; the week view
  # (Rhythm, and Quill's narrow-screen row) keys off current_week_start.
  # `CalendarHelpers.land_on/2` moves all three, so whichever theme is
  # rendering shows the day that was just selected, and records the day as
  # the page's pick rather than the booker's (`follow_timezone_change/1`).
  defp align_to(socket, date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> CalendarHelpers.land_on(socket, date)
      _invalid -> socket
    end
  end

  @doc """
  Lets the landing follow a timezone the booker has just picked.

  Today can be another date in the new zone, and the day landed on was the
  first free one in the old zone's days: it can already be past in the new
  one, where it would stay selected with no times. The landing starts again,
  dropping the selection, reopening the calendar on the new zone's today and
  re-arming to run on the month's availability the caller fetches for the new
  zone, in two cases:

    * the calendar is still where the page left it
      (`CalendarHelpers.untouched?/1`), on a day it landed on or on today with
      nothing selected;
    * the day selected, whoever chose it, is outside the booking window in the
      new zone (`CalendarHelpers.selection_out_of_window?/1`). That covers a
      day the booker clicked, and the page's own pick once a visit to the
      booking step and back has reopened it as a held day: kept, either would
      be a day that can no longer be booked.

  Otherwise the booker's calendar is left as it is: a month or week they moved
  to, or a day they chose (a click, a `?date=` link) that is still bookable. A
  reschedule is no exception: it arrives with no day of its own, so its
  selection is the landing's until the booker picks one.

  Every landing records where it left the calendar, so a second timezone change
  follows the second landing exactly as the first followed the first.
  """
  @spec follow_timezone_change(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def follow_timezone_change(socket) do
    if CalendarHelpers.untouched?(socket.assigns) or
         CalendarHelpers.selection_out_of_window?(socket.assigns) do
      socket
      |> assign(:selected_date, nil)
      |> assign(:selected_time, nil)
      |> CalendarHelpers.anchor_on_today()
      |> reset()
    else
      socket
    end
  end

  # Nothing free in the loaded range: step the window forward and ask the
  # caller to fetch again. `auto_select_months_searched` counts the hops so a
  # host with a long, empty advance window cannot turn one page load into a
  # chain of fetches.
  defp search_forward(socket) do
    months_searched = socket.assigns[:auto_select_months_searched] || 0
    {year, month} = next_month(socket.assigns[:current_year], socket.assigns[:current_month])

    cond do
      months_searched >= @max_months_searched ->
        Logger.debug("No availability found within searched window",
          user_id: socket.assigns[:organizer_user_id],
          months_searched: months_searched
        )

        {settle(socket), :done}

      beyond_booking_window?(socket, year, month) ->
        {settle(socket), :done}

      true ->
        socket =
          socket
          |> CalendarHelpers.land_on(Date.new!(year, month, 1))
          |> assign(:month_availability_map, nil)
          |> assign(:availability_status, :not_loaded)
          |> assign(:auto_select_months_searched, months_searched + 1)

        {socket, :refetch}
    end
  end

  defp next_month(year, 12), do: {year + 1, 1}
  defp next_month(year, month), do: {year, month + 1}

  # Mirrors CalendarNavigation.next_month_disabled?/4 — the search must stop
  # where the forward arrow does, or it would land the booker on a month the
  # UI refuses to navigate to.
  #
  # Reads the `:booking_window_days` assign rather than resolving the window
  # again. The window lives on the availability schedule a meeting type
  # resolves to, not on the profile, and a meeting type may open a *longer*
  # window than the organiser's default; resolving from the default here would
  # stop the search short of days the forward arrow will happily reach. The
  # assign is the same value the templates hand to `next_month_disabled?/4`,
  # which is what makes this a mirror rather than a second opinion.
  defp beyond_booking_window?(socket, year, month) do
    case socket.assigns[:booking_window_days] do
      days when is_integer(days) ->
        max_booking_date = Date.add(today_for(socket), days)
        Date.compare(Date.new!(year, month, 1), max_booking_date) != :lt

      _absent ->
        true
    end
  end

  # The booker's own timezone decides which day is "today"; using UTC here
  # would offer a day already past for anyone west of it.
  defp today_for(socket) do
    socket.assigns[:user_timezone]
    |> DateTimeUtils.now_in_timezone()
    |> DateTime.to_date()
  end
end
