defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers do
  @moduledoc "Pure helper functions for CalendarGridComponent: data loading, date/time utilities, event filtering and positioning."

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.HTML
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Timezones

  # Data loading (socket transformers)

  @spec load_integrations(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load_integrations(socket) do
    user_id = socket.assigns.current_user.id
    integrations = CalendarGrid.list_active_integrations(user_id)
    colors = CalendarGrid.get_integration_color_indices(integrations)
    prefs = CalendarGrid.get_or_create_preferences(user_id)

    owned_ids = MapSet.new(integrations, & &1.id)

    socket
    |> assign(:integrations, integrations)
    |> assign(:integration_colors, colors)
    |> assign(:owned_integration_ids, owned_ids)
    |> assign(:preferences, prefs)
    |> assign(:hidden_integration_ids, prefs.hidden_integration_ids)
    |> assign(:view, safe_view_atom(prefs.default_view))
    |> check_staleness()
  end

  @spec check_staleness(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def check_staleness(socket) do
    integrations = socket.assigns.integrations
    stale = CalendarGrid.stale_integrations(integrations)
    oldest = CalendarGrid.oldest_sync_at(stale)

    socket
    |> assign(:stale_integrations, stale)
    |> assign(:oldest_sync_at, oldest)
  end

  @spec load_events(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load_events(socket) do
    integration_ids = Enum.map(socket.assigns.integrations, & &1.id)
    {start_dt, end_dt} = range_for_view(socket.assigns)
    events = CalendarGrid.list_events_for_range(integration_ids, start_dt, end_dt)

    socket
    |> assign(:events, events)
    |> precompute_derived()
  end

  @spec precompute_derived(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def precompute_derived(socket) do
    assigns = socket.assigns
    tz = get_in(assigns, [:profile, Access.key(:timezone)]) || "UTC"
    v_events = do_visible_events(assigns.events, assigns.hidden_integration_ids)
    v_days = visible_days(assigns)

    socket
    |> assign(:user_timezone, tz)
    |> assign(:timezone_display, Timezones.format(tz))
    |> assign(:timezone_country_code, Timezones.country_code(tz))
    |> assign(:visible_events, v_events)
    |> assign(:visible_days, v_days)
  end

  @spec range_for_view(map()) :: {DateTime.t(), DateTime.t()}
  def range_for_view(%{view: :week, date: date} = assigns) do
    ws = week_start(date, assigns)
    we = Date.add(ws, 6)
    range_start = Date.add(ws, -1)
    range_end = Date.add(we, 1)

    {DateTime.new!(range_start, ~T[00:00:00], "Etc/UTC"),
     DateTime.new!(range_end, ~T[00:00:00], "Etc/UTC")}
  end

  def range_for_view(%{view: :day, date: date}) do
    range_start = Date.add(date, -1)
    range_end = Date.add(date, 1)

    {DateTime.new!(range_start, ~T[00:00:00], "Etc/UTC"),
     DateTime.new!(range_end, ~T[00:00:00], "Etc/UTC")}
  end

  def range_for_view(%{view: :month, date: date}) do
    first_of_month = Date.new!(date.year, date.month, 1)
    range_start = DateTime.new!(Date.add(first_of_month, -7), ~T[00:00:00], "Etc/UTC")
    range_end = DateTime.new!(Date.add(first_of_month, 38), ~T[00:00:00], "Etc/UTC")
    {range_start, range_end}
  end

  # Pure date/time utilities

  @spec visible_days(map()) :: [Date.t()]
  def visible_days(%{view: :week, date: date} = assigns) do
    ws = week_start(date, assigns)
    all_days = Enum.map(0..6, &Date.add(ws, &1))

    if show_weekends?(assigns) do
      all_days
    else
      Enum.reject(all_days, &weekend?/1)
    end
  end

  def visible_days(%{view: :day, date: date}), do: [date]

  def visible_days(%{view: :month, date: date} = assigns) do
    first_of_month = Date.new!(date.year, date.month, 1)
    start_atom = week_start_atom(assigns)

    grid_start = Date.beginning_of_week(first_of_month, start_atom)
    # Always show 6 weeks = 42 days
    Enum.map(0..41, &Date.add(grid_start, &1))
  end

  @spec week_start(Date.t(), map()) :: Date.t()
  def week_start(date, assigns), do: Date.beginning_of_week(date, week_start_atom(assigns))

  @spec col_count(map()) :: integer()
  def col_count(%{view: :week} = assigns), do: if(show_weekends?(assigns), do: 7, else: 5)
  def col_count(%{view: :day}), do: 1
  def col_count(%{view: :month}), do: 7

  @spec day_header_class(Date.t()) :: String.t()
  def day_header_class(day) do
    if Date.compare(day, Date.utc_today()) == :eq do
      "font-bold text-turquoise-600"
    else
      "text-tymeslot-600"
    end
  end

  @spec period_label(map()) :: String.t()
  def period_label(%{view: :week, date: date} = assigns) do
    ws = week_start(date, assigns)
    we = Date.add(ws, 6)
    start_str = Calendar.strftime(ws, "%B %-d")

    end_str =
      if ws.month == we.month do
        Calendar.strftime(we, "%-d, %Y")
      else
        Calendar.strftime(we, "%B %-d, %Y")
      end

    "#{start_str} \u2013 #{end_str}"
  end

  def period_label(%{view: :day, date: date}) do
    Calendar.strftime(date, "%A, %B %-d, %Y")
  end

  def period_label(%{view: :month, date: date}) do
    Calendar.strftime(date, "%B %Y")
  end

  @spec view_label(atom()) :: String.t()
  def view_label(:day), do: "Day"
  def view_label(:week), do: "Week"
  def view_label(:month), do: "Month"

  @spec navigate_month(Date.t(), integer()) :: Date.t()
  def navigate_month(date, delta) do
    Date.shift(Date.new!(date.year, date.month, 1), month: delta)
  end

  @spec month_cell_class(Date.t(), map()) :: String.t()
  def month_cell_class(day, assigns) do
    if day.month != assigns.date.month, do: "bg-tymeslot-50", else: "bg-white"
  end

  @spec day_events(map(), Date.t()) :: list()
  def day_events(assigns, date) do
    tz = assigns.user_timezone

    Enum.filter(visible_events(assigns), fn e ->
      not e.all_day and event_spans_day?(e, date, tz)
    end)
  end

  @spec user_timezone(map()) :: String.t()
  def user_timezone(assigns), do: assigns.user_timezone

  @spec user_tz_abbr(map()) :: String.t()
  def user_tz_abbr(assigns) do
    tz = assigns.user_timezone

    case DateTime.now(tz) do
      {:ok, dt} -> Calendar.strftime(dt, "%Z")
      _error -> tz
    end
  end

  # Event filtering

  @spec visible_events(map()) :: list()
  def visible_events(assigns), do: assigns.visible_events

  @spec do_visible_events(list(), list()) :: list()
  defp do_visible_events(events, []), do: events

  defp do_visible_events(events, hidden_ids) do
    Enum.reject(events, fn e -> e.calendar_integration_id in hidden_ids end)
  end

  # Event positioning

  @spec top_rem(DateTime.t(), String.t()) :: float()
  def top_rem(dt, tz \\ "UTC") do
    local_dt = DateTime.shift_zone!(dt, tz)
    minutes = local_dt.hour * 60 + local_dt.minute
    Float.round(minutes / 60 * 4, 3)
  end

  @spec height_rem(DateTime.t(), DateTime.t()) :: float()
  def height_rem(start_dt, end_dt) do
    duration_minutes = DateTime.diff(end_dt, start_dt, :second) / 60
    max(0.5, Float.round(duration_minutes / 60 * 4, 3))
  end

  @spec left_pct(integer(), integer()) :: float()
  def left_pct(col_idx, total_cols) do
    Float.round(col_idx / total_cols * 100, 2)
  end

  @spec width_pct(integer()) :: float()
  def width_pct(total_cols) do
    Float.round(1 / total_cols * 100, 2)
  end

  @spec color_class_for_integration(map(), term()) :: String.t()
  def color_class_for_integration(integration_colors, integration_id) do
    index = Map.get(integration_colors, integration_id)
    calendar_color_class(index)
  end

  @spec color_dot(map(), map()) :: String.t()
  def color_dot(assigns, integration) do
    color_class_for_integration(assigns.integration_colors, integration.id)
  end

  @spec color_for_event(map(), map()) :: String.t()
  def color_for_event(assigns, event) do
    color_class_for_integration(assigns.integration_colors, event.calendar_integration_id)
  end

  defp calendar_color_class(nil), do: "bg-calendar-fallback"
  defp calendar_color_class(index), do: "bg-calendar-#{index}"

  @spec format_time_range(map(), String.t()) :: String.t()
  def format_time_range(event, fmt \\ "12h") do
    if event.all_day do
      "All day"
    else
      start_str = format_datetime(event.start_at, fmt)
      end_str = format_datetime(event.end_at, fmt)
      "#{start_str} \u2013 #{end_str}"
    end
  end

  @doc """
  Formats the time range using the original (unclamped) times when available.
  Multi-day events include a short date (e.g. "10:30 Apr 1 – 11:00 Apr 2")
  so the label isn't misleading about duration.
  """
  @spec format_display_time_range(map(), String.t(), String.t()) :: String.t()
  def format_display_time_range(event, fmt \\ "12h", timezone \\ "Etc/UTC") do
    start_at = Map.get(event, :display_start_at, event.start_at)
    end_at = Map.get(event, :display_end_at, event.end_at)

    if event.all_day do
      "All day"
    else
      start_local = DateTime.shift_zone!(start_at, timezone)
      end_local = DateTime.shift_zone!(end_at, timezone)
      start_date = DateTime.to_date(start_local)
      end_date = DateTime.to_date(end_local)

      if Date.compare(start_date, end_date) == :eq do
        start_str = format_datetime(start_local, fmt)
        end_str = format_datetime(end_local, fmt)
        "#{start_str} \u2013 #{end_str}"
      else
        start_str = format_datetime_with_date(start_local, fmt)
        end_str = format_datetime_with_date(end_local, fmt)
        "#{start_str} \u2013 #{end_str}"
      end
    end
  end

  @spec format_time_range_in_tz(map(), String.t(), String.t()) :: String.t()
  def format_time_range_in_tz(event, timezone, fmt \\ "12h") do
    if event.all_day do
      "All day"
    else
      start_local = DateTime.shift_zone!(event.start_at, timezone)
      end_local = DateTime.shift_zone!(event.end_at, timezone)
      start_str = format_datetime(start_local, fmt)
      end_str = format_datetime(end_local, fmt)
      "#{start_str} \u2013 #{end_str}"
    end
  end

  defp format_datetime(dt, "24h"), do: Calendar.strftime(dt, "%H:%M")
  defp format_datetime(dt, _fmt), do: Calendar.strftime(dt, "%-I:%M %p")

  defp format_datetime_with_date(dt, "24h"), do: Calendar.strftime(dt, "%H:%M %b %-d")
  defp format_datetime_with_date(dt, _fmt), do: Calendar.strftime(dt, "%-I:%M %p %b %-d")

  @spec tz_abbr(String.t()) :: String.t()
  def tz_abbr(timezone) do
    case DateTime.now(timezone) do
      {:ok, dt} -> Calendar.strftime(dt, "%Z")
      _error -> timezone
    end
  end

  @spec datetime_to_local_parts(DateTime.t(), String.t()) ::
          %{date: String.t(), time: String.t()}
  def datetime_to_local_parts(dt, timezone) do
    local = DateTime.shift_zone!(dt, timezone)
    date = Date.to_iso8601(DateTime.to_date(local))
    time = Calendar.strftime(local, "%H:%M")
    %{date: date, time: time}
  end

  @spec url?(String.t()) :: boolean()
  def url?(str), do: String.match?(str, ~r{^https?://})

  @url_regex ~r{https?://[^\s<>"]+}

  @spec linkify_text(String.t()) :: HTML.safe()
  def linkify_text(text) do
    html =
      @url_regex
      |> Regex.split(text, include_captures: true)
      |> Enum.map_join(fn part ->
        if Regex.match?(~r{^https?://}, part) do
          display = part |> HTML.html_escape() |> HTML.safe_to_string()
          href = part |> HTML.html_escape() |> HTML.safe_to_string()

          ~s(<a href="#{href}" target="_blank" rel="noopener noreferrer" ) <>
            ~s(class="text-turquoise-600 underline break-all hover:text-turquoise-800">#{display}</a>)
        else
          part |> HTML.html_escape() |> HTML.safe_to_string()
        end
      end)

    HTML.raw(html)
  end

  @spec all_day_events_for_day(map(), Date.t()) :: list()
  def all_day_events_for_day(assigns, date) do
    Enum.filter(visible_events(assigns), fn event ->
      # end_at stores the exclusive end (iCal DTEND for all-day events is exclusive),
      # so the event covers `date` only when start_date <= date < end_date.
      event.all_day and
        Date.compare(DateTime.to_date(event.start_at), date) != :gt and
        Date.compare(DateTime.to_date(event.end_at), date) == :gt
    end)
  end

  # Preference helpers

  @spec week_start_atom(map()) :: :monday | :sunday
  def week_start_atom(%{preferences: %{week_start_day: "sunday"}}), do: :sunday
  def week_start_atom(_assigns), do: :monday

  @spec show_weekends?(map()) :: boolean()
  def show_weekends?(%{preferences: %{show_weekends: false}}), do: false
  def show_weekends?(_assigns), do: true

  @spec show_week_numbers?(map()) :: boolean()
  def show_week_numbers?(%{preferences: %{show_week_numbers: true}}), do: true
  def show_week_numbers?(_assigns), do: false

  @spec time_format(map()) :: String.t()
  def time_format(%{preferences: %{time_format: fmt}}), do: fmt
  def time_format(_assigns), do: "12h"

  @valid_views %{"week" => :week, "day" => :day, "month" => :month}
  defp safe_view_atom(view) when is_binary(view), do: Map.get(@valid_views, view, :week)

  defp weekend?(date), do: Date.day_of_week(date) in [6, 7]

  @spec format_hour(integer(), map()) :: String.t()
  def format_hour(hour, assigns) do
    if time_format(assigns) == "24h" do
      String.pad_leading(Integer.to_string(hour), 2, "0") <> ":00"
    else
      Calendar.strftime(Time.new!(hour, 0, 0), "%I %p")
    end
  end

  @spec week_number(Date.t()) :: integer()
  def week_number(date) do
    {_year, week} = :calendar.iso_week_number(Date.to_erl(date))
    week
  end

  @spec day_name_headers(map()) :: [String.t()]
  def day_name_headers(assigns) do
    monday_start = ~w(Mon Tue Wed Thu Fri Sat Sun)
    sunday_start = ~w(Sun Mon Tue Wed Thu Fri Sat)

    if week_start_atom(assigns) == :sunday, do: sunday_start, else: monday_start
  end

  # Overlap layout for day column

  @spec positioned_events_for_day(map(), Date.t()) :: list()
  def positioned_events_for_day(assigns, date) do
    tz = assigns.user_timezone

    events =
      visible_events(assigns)
      |> Enum.filter(fn e ->
        not e.all_day and event_spans_day?(e, date, tz)
      end)
      |> Enum.map(&clamp_event_to_day(&1, date, tz))
      |> Enum.sort_by(& &1.start_at)

    overlap_layout(events)
  end

  defp day_boundary_utc(date, tz) do
    day_start = DateTime.shift_zone!(DateTime.new!(date, ~T[00:00:00], tz), "Etc/UTC")
    day_end = DateTime.shift_zone!(DateTime.new!(Date.add(date, 1), ~T[00:00:00], tz), "Etc/UTC")
    {day_start, day_end}
  end

  # Does this event overlap with the given calendar day (in the user's timezone)?
  defp event_spans_day?(event, date, tz) do
    {day_start, day_end} = day_boundary_utc(date, tz)

    DateTime.compare(event.start_at, day_end) == :lt and
      DateTime.compare(event.end_at, day_start) == :gt
  end

  # Clamp an event's display start/end to the boundaries of a single calendar day.
  # Preserves original times in :display_start_at / :display_end_at for the time label.
  defp clamp_event_to_day(event, date, tz) do
    {day_start, day_end} = day_boundary_utc(date, tz)

    clamped_start =
      if DateTime.compare(event.start_at, day_start) == :lt, do: day_start, else: event.start_at

    clamped_end =
      if DateTime.compare(event.end_at, day_end) == :gt, do: day_end, else: event.end_at

    event
    |> Map.put(:display_start_at, event.start_at)
    |> Map.put(:display_end_at, event.end_at)
    |> Map.put(:start_at, clamped_start)
    |> Map.put(:end_at, clamped_end)
  end

  @spec overlap_layout(list()) :: list()
  def overlap_layout([]), do: []

  def overlap_layout(events) do
    # Greedy slot assignment: assign each event to the first available column slot
    # that doesn't overlap with existing events in that slot
    slots =
      Enum.reduce(events, [], fn event, slots ->
        col_idx =
          Enum.find_index(slots, fn col_events ->
            last = List.last(col_events)
            last == nil or DateTime.compare(last.end_at, event.start_at) != :gt
          end)

        if col_idx do
          List.update_at(slots, col_idx, &(&1 ++ [event]))
        else
          slots ++ [[event]]
        end
      end)

    total_cols = length(slots)

    for {col_events, col_idx} <- Enum.with_index(slots),
        event <- col_events do
      {event, col_idx, total_cols}
    end
  end
end
