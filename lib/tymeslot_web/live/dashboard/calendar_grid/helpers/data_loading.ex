defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.DataLoading do
  @moduledoc "Socket transformers that load integrations, events, and derived state for the calendar grid."

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Timezones
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.PreferenceHelpers

  # Number of days the agenda view looks ahead from the current date.
  @agenda_window_days 30

  @spec load_integrations(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load_integrations(socket) do
    user_id = socket.assigns.current_user.id
    integrations = CalendarGrid.list_active_integrations(user_id)
    colors = CalendarGrid.integration_colour_classes(integrations)
    prefs = CalendarGrid.get_or_create_preferences(user_id)

    owned_ids = MapSet.new(integrations, & &1.id)

    video_integrations =
      user_id
      |> Video.list_integrations()
      |> Enum.filter(& &1.is_active)

    socket
    |> assign(:integrations, integrations)
    |> assign(:integration_colors, colors)
    |> assign(:owned_integration_ids, owned_ids)
    |> assign(:preferences, prefs)
    |> assign(:hidden_integration_ids, prefs.hidden_integration_ids)
    |> assign(:video_integrations, video_integrations)
    |> assign_calendar_appearances(user_id)
    |> check_staleness()
  end

  @doc """
  Assigns the set of cached events that are busy-block mirrors of an event on
  another of the organiser's calendars.

  A mirror exists for external tools reading the target calendar; drawing it in
  the organiser's own grid would double-draw every synchronised event beside its
  source, which is noise rather than information.

  Called from `load_events/1` rather than only from `load_integrations/1`, and
  the coupling is the point: this set is a filter over the events that call
  just fetched, so anything that reloads the events without reloading it hands
  the filter a stale answer. That is not hypothetical — "Refresh calendars"
  reloads events alone, which is precisely when a sync has just written the
  placeholders the set is meant to know about, and the organiser watched their
  own mirrors appear beside their sources.

  Not moved into `precompute_derived/1`, which is the other candidate home:
  that runs on every inline edit, every drag, and every live cache update, none
  of which change the mirror set, and each would gain a database round trip.
  `load_events/1` is already going to the database for the events themselves,
  so this rides alongside as one further indexed lookup on
  `calendar_sync_mirrors_target_uid_index`.

  The set is keyed on `{integration_id, uid}` from the mirrors table, never on
  `created_by_tymeslot`. That flag means "Tymeslot wrote this", which is equally
  true of an event a booking created, so filtering on it would hide the
  organiser's own bookings.
  """
  @spec assign_mirror_uids(Phoenix.LiveView.Socket.t(), [map()]) :: Phoenix.LiveView.Socket.t()
  def assign_mirror_uids(socket, integrations) do
    mirror_uids =
      integrations
      |> Enum.map(& &1.id)
      |> CalendarSyncMirrorQueries.mirror_uids_for_integrations()

    assign(socket, :mirror_uids, mirror_uids)
  end

  @doc """
  Assigns the three maps derived from the organiser's per-calendar choices.

  All three move together on purpose. `:calendar_colors` paints the grid,
  `:calendar_colour_keys` marks the right swatch pressed in the picker, and
  `:hidden_calendar_keys` filters the events. Refreshing only some of them after
  a write leaves the grid and the control it was clicked from disagreeing.
  """
  @spec assign_calendar_appearances(Phoenix.LiveView.Socket.t(), integer()) ::
          Phoenix.LiveView.Socket.t()
  def assign_calendar_appearances(socket, user_id) do
    appearances = Appearance.list_for_user(user_id)

    socket
    |> assign(:calendar_colors, CalendarGrid.calendar_colour_classes(appearances))
    |> assign(:calendar_colour_keys, Appearance.colour_keys(appearances))
    |> assign(:hidden_calendar_keys, Appearance.hidden_keys(appearances))
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
    integrations = socket.assigns.integrations
    integration_ids = Enum.map(integrations, & &1.id)
    {start_dt, end_dt} = range_for_view(socket.assigns)

    cached = CalendarGrid.list_events_for_range(integration_ids, start_dt, end_dt)

    # Dedupe against every cached row, not just the selection-visible ones: a
    # booking whose synced copy the user has hidden must stay hidden, not
    # reappear through its projection.
    synced_ids =
      cached
      |> Enum.map(& &1.provider_event_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    booking_events =
      CalendarGrid.list_booking_events_for_range(
        socket.assigns.current_user.id,
        start_dt,
        end_dt,
        synced_ids
      )

    events = filter_events_by_selection(cached, integrations) ++ booking_events

    socket
    |> assign(:events, events)
    |> assign_mirror_uids(integrations)
    |> precompute_derived()
  end

  # Cached events outlive selection changes: a user can toggle a calendar
  # off in integration settings, but rows the previous sync wrote stay in
  # the cache until pruning runs. Filter them out here so the grid honours
  # the user's current selection immediately rather than waiting for the
  # next sync cycle to delete them.
  defp filter_events_by_selection(events, integrations) do
    integration_by_id = Map.new(integrations, &{&1.id, &1})

    Enum.filter(events, fn event ->
      case Map.fetch(integration_by_id, event.calendar_integration_id) do
        :error -> true
        {:ok, integration} -> Selection.event_visible?(event, integration)
      end
    end)
  end

  @spec precompute_derived(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def precompute_derived(socket) do
    assigns = socket.assigns
    raw_tz = get_in(assigns, [:profile, Access.key(:timezone)]) || Timezones.fallback()
    user_id = get_in(assigns, [:current_user, Access.key(:id)])
    tz = Timezones.validate_or_utc(raw_tz, user_id: user_id)

    v_events =
      do_visible_events(
        assigns.events,
        assigns.hidden_integration_ids,
        Map.get(assigns, :hidden_calendar_keys, MapSet.new()),
        Map.get(assigns, :mirror_uids, MapSet.new())
      )

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
    ws = PreferenceHelpers.week_start(date, assigns)
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

  def range_for_view(%{view: :three_day, date: date}) do
    range_start = Date.add(date, -1)
    range_end = Date.add(date, 3)

    {DateTime.new!(range_start, ~T[00:00:00], "Etc/UTC"),
     DateTime.new!(range_end, ~T[00:00:00], "Etc/UTC")}
  end

  def range_for_view(%{view: :month, date: date}) do
    first_of_month = Date.new!(date.year, date.month, 1)
    range_start = DateTime.new!(Date.add(first_of_month, -7), ~T[00:00:00], "Etc/UTC")
    range_end = DateTime.new!(Date.add(first_of_month, 38), ~T[00:00:00], "Etc/UTC")
    {range_start, range_end}
  end

  # Agenda window: the current date forward 30 days. A one-day pad on each side
  # keeps timezone-boundary events that touch the window's edge in range.
  def range_for_view(%{view: :agenda, date: date}) do
    range_start = Date.add(date, -1)
    range_end = Date.add(date, @agenda_window_days + 1)

    {DateTime.new!(range_start, ~T[00:00:00], "Etc/UTC"),
     DateTime.new!(range_end, ~T[00:00:00], "Etc/UTC")}
  end

  # Private helpers

  # An event is hidden when its whole account is hidden, when the organiser has
  # hidden the single calendar it sits in, or when it is a busy-block mirror of
  # an event on another of their calendars. The first two are separate controls
  # over separate stores, so both are consulted rather than one deriving the
  # other: hiding an account must not erase the per-calendar choices underneath
  # it, which the organiser gets back when they show the account again. The
  # third is not a control at all — a mirror is never shown.
  #
  # The cheap-exit test names all three sources. Leaving the mirror set out of
  # it would return every event untouched whenever no account and no calendar
  # is hidden, which is the ordinary case, so mirrors would leak into the grid
  # for almost every organiser while the filter below looked correct.
  defp do_visible_events(events, hidden_ids, hidden_keys, mirror_uids) do
    if hidden_ids == [] and MapSet.size(hidden_keys) == 0 and MapSet.size(mirror_uids) == 0 do
      events
    else
      Enum.reject(events, &hidden_event?(&1, hidden_ids, hidden_keys, mirror_uids))
    end
  end

  defp hidden_event?(event, hidden_ids, hidden_keys, mirror_uids) do
    event.calendar_integration_id in hidden_ids or
      MapSet.member?(
        hidden_keys,
        {event.calendar_integration_id, Map.get(event, :provider_calendar_id)}
      ) or
      MapSet.member?(mirror_uids, {event.calendar_integration_id, Map.get(event, :uid)})
  end

  defp visible_days(%{view: :week, date: date} = assigns) do
    ws = PreferenceHelpers.week_start(date, assigns)
    all_days = Enum.map(0..6, &Date.add(ws, &1))

    if PreferenceHelpers.show_weekends?(assigns) do
      all_days
    else
      Enum.reject(all_days, &weekend?/1)
    end
  end

  defp visible_days(%{view: :day, date: date}), do: [date]

  defp visible_days(%{view: :three_day, date: date}),
    do: Enum.map(0..2, &Date.add(date, &1))

  defp visible_days(%{view: :agenda, date: date}),
    do: Enum.map(0..@agenda_window_days, &Date.add(date, &1))

  defp visible_days(%{view: :month, date: date} = assigns) do
    # Always show 6 weeks = 42 days; shared with the mini-month picker.
    PreferenceHelpers.month_matrix(date, PreferenceHelpers.week_start_atom(assigns))
  end

  defp weekend?(date), do: Date.day_of_week(date) in [6, 7]
end
