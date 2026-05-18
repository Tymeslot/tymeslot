defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.DataLoading do
  @moduledoc "Socket transformers that load integrations, events, and derived state for the calendar grid."

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Timezones
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.PreferenceHelpers

  @spec load_integrations(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load_integrations(socket) do
    user_id = socket.assigns.current_user.id
    integrations = CalendarGrid.list_active_integrations(user_id)
    colors = CalendarGrid.get_integration_color_indices(integrations)
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
    integrations = socket.assigns.integrations
    integration_ids = Enum.map(integrations, & &1.id)
    {start_dt, end_dt} = range_for_view(socket.assigns)

    events =
      integration_ids
      |> CalendarGrid.list_events_for_range(start_dt, end_dt)
      |> filter_events_by_selection(integrations)

    socket
    |> assign(:events, events)
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
    raw_tz = get_in(assigns, [:profile, Access.key(:timezone)]) || "Etc/UTC"
    user_id = get_in(assigns, [:current_user, Access.key(:id)])
    tz = Timezones.validate_or_utc(raw_tz, user_id: user_id)
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

  # Private helpers

  defp do_visible_events(events, []), do: events

  defp do_visible_events(events, hidden_ids) do
    Enum.reject(events, fn e -> e.calendar_integration_id in hidden_ids end)
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

  defp visible_days(%{view: :month, date: date} = assigns) do
    first_of_month = Date.new!(date.year, date.month, 1)
    start_atom = PreferenceHelpers.week_start_atom(assigns)

    grid_start = Date.beginning_of_week(first_of_month, start_atom)
    # Always show 6 weeks = 42 days
    Enum.map(0..41, &Date.add(grid_start, &1))
  end

  defp weekend?(date), do: Date.day_of_week(date) in [6, 7]
end
