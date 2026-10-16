defmodule TymeslotWeb.Dashboard.Calendar.SurfaceData do
  @moduledoc """
  Socket transformers that load what the calendar surface shows: the
  organiser's preferences and calendars, the period the URL names, and the
  events for that period plus one period either side, which is what lets the
  `CalendarCanvas` hook step to a neighbouring period without waiting.

  Queries run only on a connected socket. The dead render gets the period
  from the URL and the clock alone, enough to draw the toolbar and the
  skeleton.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.CalendarDirectory
  alias Tymeslot.CalendarGrid.ColourTokens
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.EventWindow
  alias Tymeslot.CalendarGrid.Period
  alias Tymeslot.CalendarGrid.WorkingHours
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesSchema
  alias Tymeslot.Profiles

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "The assigns every render can rely on, before anything is loaded."
  @spec defaults(socket()) :: socket()
  def defaults(socket) do
    assign(socket,
      ready?: false,
      params: %{},
      preferences: %CalendarPreferencesSchema{},
      integrations: [],
      integration_tokens: %{},
      calendar_tokens: %{},
      hidden_integration_ids: [],
      hidden_calendar_keys: MapSet.new(),
      accounts: [],
      hidden_count: 0,
      working_hours: WorkingHours.fallback(),
      window_events: [],
      events: [],
      events_by_id: %{},
      window: nil,
      rail_open: true,
      open_menu: nil,
      preview: nil
    )
  end

  @doc """
  Brings the socket in line with the parent's assigns: the first connected
  update loads everything; later ones reload the window only when the URL
  names a different period, and push it to the hook.
  """
  @spec sync(socket()) :: socket()
  def sync(socket) do
    cond do
      not connected?(socket) ->
        socket |> assign_clock() |> apply_params()

      not socket.assigns.ready? ->
        socket |> load_context() |> apply_params() |> load_window() |> assign(:ready?, true)

      true ->
        follow_params(socket)
    end
  end

  @doc "Loads preferences, calendars, colours, hidden choices and working hours."
  @spec load_context(socket()) :: socket()
  def load_context(socket) do
    user_id = socket.assigns.current_user.id
    preferences = CalendarGrid.get_or_create_preferences(user_id)
    integrations = CalendarGrid.list_active_integrations(user_id)
    appearances = Appearance.list_for_user(user_id)

    socket
    |> assign_clock()
    |> assign(
      preferences: preferences,
      integrations: integrations,
      integration_tokens: ColourTokens.for_integrations(integrations),
      calendar_tokens: ColourTokens.for_calendars(appearances),
      hidden_integration_ids: preferences.hidden_integration_ids,
      hidden_calendar_keys: Appearance.hidden_keys(appearances),
      working_hours: WorkingHours.for_profile(socket.assigns[:profile])
    )
    |> assign_accounts()
  end

  @doc "Rebuilds the rail's accounts and the hidden-calendar count."
  @spec assign_accounts(socket()) :: socket()
  def assign_accounts(socket) do
    %{
      integrations: integrations,
      integration_tokens: integration_tokens,
      calendar_tokens: calendar_tokens,
      hidden_integration_ids: hidden_ids,
      hidden_calendar_keys: hidden_keys
    } = socket.assigns

    accounts =
      CalendarDirectory.accounts(
        integrations,
        integration_tokens,
        calendar_tokens,
        hidden_ids,
        hidden_keys
      )

    assign(socket, accounts: accounts, hidden_count: CalendarDirectory.hidden_count(accounts))
  end

  @doc "Sets the period from the URL (or the defaults) and resets per-period UI."
  @spec apply_params(socket()) :: socket()
  def apply_params(socket) do
    {view, date} = target(socket.assigns)

    assign(socket,
      view: view,
      date: date,
      mini_cursor: Date.beginning_of_month(date),
      preview: nil,
      open_menu: nil
    )
  end

  @doc "Loads the events for the period plus one period either side."
  @spec load_window(socket()) :: socket()
  def load_window(socket) do
    %{current_user: user, view: view, date: date, preferences: preferences, timezone: timezone} =
      socket.assigns

    window =
      Period.window(
        view,
        date,
        Period.week_start(preferences.week_start_day),
        preferences.show_weekends
      )

    {start_dt, end_dt} = EventWindow.utc_range(window.first, window.last, timezone)

    window_events =
      EventWindow.list_events(user.id, socket.assigns.integrations, start_dt, end_dt)

    socket |> assign(window: window, window_events: window_events) |> filter_events()
  end

  # Applies the hidden choices to the window's unfiltered events, so a toggle
  # needs no query.
  defp filter_events(socket) do
    events =
      EventWindow.reject_hidden(
        socket.assigns.window_events,
        socket.assigns.hidden_integration_ids,
        socket.assigns.hidden_calendar_keys
      )

    assign(socket, events: events, events_by_id: Map.new(events, &{EventPayload.id(&1), &1}))
  end

  @doc "The days the current view shows."
  @spec days(map()) :: [Date.t()]
  def days(%{view: view, date: date, preferences: preferences}),
    do:
      Period.days(
        view,
        date,
        Period.week_start(preferences.week_start_day),
        preferences.show_weekends
      )

  @doc "The display settings the hook draws with."
  @spec settings(map()) :: map()
  def settings(assigns) do
    preferences = assigns.preferences

    %{
      week_start: Atom.to_string(Period.week_start(preferences.week_start_day)),
      show_weekends: preferences.show_weekends,
      density: preferences.density,
      fold_night: preferences.fold_night,
      time_format: assigns.time_format,
      working_hours: assigns.working_hours
    }
  end

  @doc "The payload for the loaded window; `reset` tells the hook to drop its cache first."
  @spec payload(map(), boolean()) :: map()
  def payload(assigns, reset) do
    EventPayload.build(%{
      view: assigns.view,
      date: assigns.date,
      window: assigns.window,
      now: Clock.utc_now(),
      timezone: assigns.timezone,
      integration_tokens: assigns.integration_tokens,
      calendar_tokens: assigns.calendar_tokens,
      events: assigns.events,
      settings: settings(assigns),
      reset: reset
    })
  end

  @doc "Pushes the loaded window to the hook."
  @spec push_events(socket(), boolean()) :: socket()
  def push_events(socket, reset),
    do: push_event(socket, "calendar:events", payload(socket.assigns, reset))

  @doc "Pushes the display settings to the hook."
  @spec push_settings(socket()) :: socket()
  def push_settings(socket), do: push_event(socket, "calendar:settings", settings(socket.assigns))

  @doc """
  After a visibility change: rebuild the rail, re-filter the loaded window
  (no query) and push with a cache reset.
  """
  @spec refresh(socket()) :: socket()
  def refresh(socket), do: socket |> assign_accounts() |> filter_events() |> push_events(true)

  @doc "After a sync or an outside change: reload everything and push with a cache reset."
  @spec reload(socket()) :: socket()
  def reload(socket), do: socket |> load_context() |> load_window() |> push_events(true)

  @doc """
  Records a saved preference in the assigns. The upsert's return value is not
  used for this: it is built from the attributes passed, so its other fields
  are defaults rather than what the row holds.
  """
  @spec put_preference(socket(), atom(), term()) :: socket()
  def put_preference(socket, key, value),
    do: assign(socket, :preferences, Map.put(socket.assigns.preferences, key, value))

  defp follow_params(socket) do
    socket = assign_clock(socket)

    if target(socket.assigns) == {socket.assigns.view, socket.assigns.date},
      do: socket,
      else: socket |> apply_params() |> load_window() |> push_events(false)
  end

  defp target(%{params: params, preferences: preferences, today: today}) do
    params = params || %{}

    {Period.parse_view(params["view"], Period.default_view(preferences.default_view)),
     Period.parse_date(params["date"], today)}
  end

  defp assign_clock(socket) do
    timezone = Profiles.timezone(socket.assigns[:profile])

    today =
      case DateTime.shift_zone(Clock.utc_now(), timezone) do
        {:ok, local} -> DateTime.to_date(local)
        {:error, _reason} -> Clock.utc_today()
      end

    assign(socket, timezone: timezone, today: today)
  end
end
