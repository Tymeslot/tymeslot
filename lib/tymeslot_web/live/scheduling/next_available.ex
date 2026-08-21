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

  A date carried in on the URL — a reschedule link, a shared link — is a
  deliberate choice and is left untouched; `apply/1` only fills a blank
  selection.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Utils.DateTimeUtils

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

  The refetch is handed back rather than performed here because the two
  fetch paths differ: tests resolve availability synchronously, production
  spawns a task whose result arrives as a message. Returning the
  instruction lets each caller re-enter its own path, and keeps this
  module free of a dependency on the fetcher that calls it.
  """
  @spec apply(Phoenix.LiveView.Socket.t()) :: {Phoenix.LiveView.Socket.t(), :done | :refetch}
  def apply(socket) do
    if skip?(socket) do
      {socket, :done}
    else
      case first_available_date(socket) do
        nil -> search_forward(socket)
        date -> {select(socket, date), :done}
      end
    end
  end

  # An explicit selection always wins over a computed one. A date named in the
  # URL is seeded onto the socket by `do_handle_schedule_entry/2` before the
  # fetch that triggers this runs, so a reschedule or shared link keeps the day
  # it names rather than having it replaced by the earliest free one.
  defp skip?(socket) do
    socket.assigns[:selected_date] not in [nil, ""] or
      socket.assigns[:is_rescheduling] == true or
      socket.assigns[:current_state] != :schedule
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

  # Moves the visible window onto the chosen day before selecting it, then
  # asks for its slots. `handle_schedule_date_selection/2` in the theme core
  # does the same three things on a click; this is that path without the
  # click, so the two stay in step.
  defp select(socket, date_string) do
    socket
    |> align_to(date_string)
    |> assign(:selected_date, date_string)
    |> assign(:selected_time, nil)
    |> assign(:loading_slots, true)
    |> assign(:calendar_error, nil)
    |> tap(fn _socket -> send(self(), {:load_slots, date_string}) end)
  end

  # The month view keys off current_year/current_month; the week view
  # (Rhythm) keys off current_week_start. Both move, so whichever theme is
  # rendering shows the day that was just selected.
  defp align_to(socket, date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        socket
        |> assign(:current_year, date.year)
        |> assign(:current_month, date.month)
        |> assign(:current_week_start, Date.beginning_of_week(date, :monday))

      _invalid ->
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

        {socket, :done}

      beyond_booking_window?(socket, year, month) ->
        {socket, :done}

      true ->
        socket =
          socket
          |> assign(:current_year, year)
          |> assign(:current_month, month)
          |> assign(
            :current_week_start,
            Date.beginning_of_week(Date.new!(year, month, 1), :monday)
          )
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
