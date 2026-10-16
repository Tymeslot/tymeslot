defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.DataLoading do
  @moduledoc "Socket transformers that load integrations, events, and derived state for the calendar grid."

  import Phoenix.Component, only: [assign: 3]

  require Logger

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventWindow
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Meetings
  alias Tymeslot.Profiles
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
  defp check_staleness(socket) do
    integrations = socket.assigns.integrations
    stale = CalendarGrid.stale_integrations(integrations)
    oldest = CalendarGrid.oldest_sync_at(stale)

    socket
    |> assign(:stale_integrations, stale)
    |> assign(:oldest_sync_at, oldest)
  end

  @spec load_events(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load_events(socket) do
    # The window is the viewer's days in the viewer's zone, so a zone that
    # just changed has to be assigned before it is computed.
    socket = assign_timezone(socket)
    {start_dt, end_dt} = range_for_view(socket.assigns)

    # Shared with the redesigned calendar, so the two surfaces load the same
    # events for the same days (see `EventWindow.list_events/4`).
    events =
      EventWindow.list_events(
        socket.assigns.current_user.id,
        socket.assigns.integrations,
        start_dt,
        end_dt
      )

    # The group meetings with live seats in the same range, shown locked:
    # their time belongs to the bookers rather than the calendar. Loaded with
    # the events so the set always covers what is on screen; the handlers
    # re-check the lock against the database before acting.
    group_booking_uids =
      Meetings.group_booking_uids_for_user(socket.assigns.current_user.id, start_dt, end_dt)

    socket
    |> assign(:events, events)
    |> assign(:group_booking_uids, group_booking_uids)
    |> derive()
  end

  @spec precompute_derived(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def precompute_derived(socket), do: socket |> assign_timezone() |> derive()

  defp derive(socket) do
    assigns = socket.assigns

    v_events =
      EventWindow.reject_hidden(
        assigns.events,
        assigns.hidden_integration_ids,
        Map.get(assigns, :hidden_calendar_keys, MapSet.new())
      )

    v_days = visible_days(assigns)

    socket
    |> assign(:visible_events, v_events)
    |> assign(:visible_days, v_days)
  end

  @doc """
  Resolves the profile's timezone into the `user_timezone` assigns by the
  owner-zone rule (`Profiles.timezone/1`), the clock the booking engine reads
  the same host on. A stored zone the rule cannot use is logged once here, so
  operators can find the account.

  Split from `precompute_derived/1` so the initial load can know the user's
  timezone before it picks the date the grid opens on.
  """
  @spec assign_timezone(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_timezone(socket) do
    assigns = socket.assigns
    tz = Profiles.timezone(assigns[:profile])
    warn_unusable_zone(assigns[:profile], tz, get_in(assigns, [:current_user, Access.key(:id)]))

    socket
    |> assign(:user_timezone, tz)
    |> assign(:timezone_display, Timezones.format(tz))
    |> assign(:timezone_country_code, Timezones.country_code(tz))
  end

  defp warn_unusable_zone(%{timezone: stored}, tz, user_id)
       when is_binary(stored) and stored != tz do
    Logger.warning("Invalid user timezone; the calendar shows the default zone",
      timezone: stored,
      user_id: user_id
    )
  end

  defp warn_unusable_zone(_profile, _tz, _user_id), do: :ok

  @doc """
  The UTC window the grid loads events for: from midnight of the first visible
  day to midnight after the last, both in the viewer's zone. The event queries
  match on overlap, so an event that starts before the window and runs into it
  is loaded without any padding, and nothing outside what the viewer can see is.
  """
  @spec range_for_view(map()) :: {DateTime.t(), DateTime.t()}
  def range_for_view(%{user_timezone: tz} = assigns) do
    days = visible_days(assigns)
    EventWindow.utc_range(List.first(days), List.last(days), tz)
  end

  @doc "The UTC instant `date` begins in `tz`; see `EventWindow.local_midnight/2`."
  @spec local_midnight(Date.t(), String.t()) :: DateTime.t()
  defdelegate local_midnight(date, tz), to: EventWindow

  # Private helpers

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
