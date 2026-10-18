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
  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.EventWindow
  alias Tymeslot.CalendarGrid.Period
  alias Tymeslot.CalendarGrid.WorkingHours
  alias Tymeslot.CalendarGrid.WriteQueue
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesSchema
  alias Tymeslot.Profiles
  alias TymeslotWeb.Dashboard.Calendar.Deletion
  alias TymeslotWeb.Dashboard.Calendar.PendingDeletes
  alias TymeslotWeb.Dashboard.Calendar.Preview
  alias TymeslotWeb.Dashboard.Calendar.SyncStatus
  alias TymeslotWeb.Dashboard.Calendar.UndoStack
  alias TymeslotWeb.Dashboard.Calendar.Writes

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "The assigns every render can rely on, before anything is loaded."
  @spec defaults(socket()) :: socket()
  def defaults(socket) do
    assign(socket,
      ready?: false,
      pending_reload: nil,
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
      preview: nil,
      panel: nil,
      event_writes: WriteQueue.new(),
      writes_adopted_after: nil,
      undo: UndoStack.new(),
      undoing: %{},
      toast: nil,
      series_prompt: nil,
      delete_prompt: nil,
      pending_deletes: %{},
      pending_creates: %{},
      syncing_ids: MapSet.new(),
      failure_counts: %{},
      sync_refs: %{}
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
        socket
        |> load_context()
        |> apply_params()
        |> Deletion.resume()
        |> load_window()
        |> Writes.adopt()
        |> SyncStatus.load_persisted()
        |> SyncStatus.refresh_stale()
        |> assign(:ready?, true)

      true ->
        socket |> adopt_if_revived() |> follow_params()
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
      calendar_tokens: ColourTokens.for_calendars(integrations, appearances),
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
    %{current_user: user, timezone: timezone} = socket.assigns

    window = window_for(socket.assigns)

    {start_dt, end_dt} = EventWindow.utc_range(window.first, window.last, timezone)

    window_events =
      EventWindow.list_events(user.id, socket.assigns.integrations, start_dt, end_dt)

    socket |> assign(window: window, window_events: window_events) |> filter_events()
  end

  # Applies the hidden choices to the window's unfiltered events, so a toggle
  # needs no query.
  defp filter_events(socket) do
    events =
      socket.assigns.window_events
      |> EventWindow.reject_hidden(
        socket.assigns.hidden_integration_ids,
        socket.assigns.hidden_calendar_keys
      )
      |> PendingDeletes.reject(socket.assigns.pending_deletes)

    socket
    |> assign(events: events, events_by_id: Map.new(events, &{EventPayload.id(&1), &1}))
    |> rebuild_preview()
  end

  # An open preview was built from the events as they were: rebuild it from
  # the reloaded ones, or close it when its event is gone (hidden, deleted,
  # outside the new window).
  defp rebuild_preview(%{assigns: %{preview: %{id: id}}} = socket) do
    case Map.fetch(socket.assigns.events_by_id, id) do
      {:ok, event} ->
        assign(socket, :preview, Preview.build(event, Preview.context(socket.assigns)))

      :error ->
        assign(socket, :preview, nil)
    end
  end

  defp rebuild_preview(socket), do: socket

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
      working_hours: assigns.working_hours,
      calendars: CalendarDirectory.choices(assigns.accounts),
      default_calendar: CalendarDirectory.default_calendar(assigns.integrations)
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
      integrations: assigns.integrations,
      events: assigns.events,
      drafts: drafts(assigns),
      settings: settings(assigns),
      reset: reset
    })
  end

  # Creates still saving, in draft id order, then the side panel's unsaved
  # "New event" draft (see `EventPayload.draft/4`).
  defp drafts(assigns) do
    pending =
      assigns
      |> Map.get(:pending_creates, %{})
      |> Enum.sort()
      |> Enum.map(fn {id, params} -> {id, params, true} end)

    pending ++ panel_draft(Map.get(assigns, :panel))
  end

  defp panel_draft(%{mode: :new, draft: %CreateParams{} = params} = panel),
    do: [{Map.get(panel, :draft_id) || "panel", params, false}]

  defp panel_draft(_panel), do: []

  @doc "Pushes the loaded window to the hook."
  @spec push_events(socket(), boolean()) :: socket()
  def push_events(socket, reset),
    do: push_event(socket, "calendar:events", payload(socket.assigns, reset))

  @doc "Pushes the display settings to the hook."
  @spec push_settings(socket()) :: socket()
  def push_settings(socket), do: push_event(socket, "calendar:settings", settings(socket.assigns))

  @doc """
  Shows `event` in place of the loaded event with the same id (a change
  shown before the provider has answered, or the event as a write left it),
  without pushing.
  """
  @spec show_event(socket(), map()) :: socket()
  def show_event(socket, event) do
    id = EventPayload.id(event)

    window_events =
      Enum.map(socket.assigns.window_events, &if(EventPayload.id(&1) == id, do: event, else: &1))

    socket |> assign(:window_events, window_events) |> filter_events()
  end

  @doc "Applies hidden calendars and pending deletes to the loaded window again, without pushing."
  @spec refilter(socket()) :: socket()
  def refilter(socket), do: filter_events(socket)

  @doc """
  After a visibility change: rebuild the rail, re-filter the loaded window
  (no query) and push with a cache reset.
  """
  @spec refresh(socket()) :: socket()
  def refresh(socket), do: socket |> assign_accounts() |> filter_events() |> push_events(true)

  @doc """
  After a sync or an outside change, push with a cache reset. `:full` reloads
  the context (calendars, colours, preferences) as well as the events;
  `:events` reloads the events alone.
  """
  @spec reload(socket(), :full | :events) :: socket()
  def reload(socket, scope \\ :full)
  def reload(socket, :full), do: socket |> load_context() |> reload(:events)

  def reload(socket, :events),
    do: socket |> Deletion.prune() |> load_window() |> push_events(true)

  @doc """
  Records a saved preference in the assigns. The upsert's return value is not
  used for this: it is built from the attributes passed, so its other fields
  are defaults rather than what the row holds.
  """
  @spec put_preference(socket(), atom(), term()) :: socket()
  def put_preference(socket, key, value),
    do: assign(socket, :preferences, Map.put(socket.assigns.preferences, key, value))

  # The same period again only closes the date picker. A different day whose
  # window is the one already loaded (another day of the visible week) updates
  # the title and range but needs no query: the hook already holds the events.
  # Either way the hook still hears which period the URL settled on
  # (`calendar:period`), because it holds a navigation as pending until the
  # server confirms it and follows nothing else (not even Back) meanwhile.
  defp follow_params(socket) do
    socket = assign_clock(socket)
    %{view: view, date: date, window: loaded} = socket.assigns

    case target(socket.assigns) do
      {^view, ^date} ->
        socket |> assign(:open_menu, nil) |> push_period()

      _other ->
        socket = apply_params(socket)

        if window_for(socket.assigns) == loaded,
          do: push_period(socket),
          else: socket |> load_window() |> push_events(false)
    end
  end

  # LiveView revives a surface rendered again before the browser confirmed
  # its removal (the organiser left the calendar and came straight back). It
  # takes back the queue its guardian has been driving since, as a surface
  # mounted afresh does, and reloads what those writes changed. The gate is
  # the one the old grid uses: `calendar_left` counts departures, and the
  # surface remembers the count its queue was adopted at.
  defp adopt_if_revived(socket) do
    if socket.assigns[:calendar_left] == socket.assigns.writes_adopted_after,
      do: socket,
      else: socket |> Writes.adopt() |> reload(:events) |> reset_undoing()
  end

  # While detached the guardian drove the writes, so `Manipulation.settled/2`
  # and `forget/2` never ran for them; their entries would otherwise leak.
  defp reset_undoing(socket), do: assign(socket, :undoing, %{})

  defp push_period(%{assigns: %{view: view, date: date}} = socket),
    do:
      push_event(socket, "calendar:period", %{
        view: Atom.to_string(view),
        date: Date.to_iso8601(date)
      })

  defp window_for(%{view: view, date: date, preferences: preferences}),
    do:
      Period.window(
        view,
        date,
        Period.week_start(preferences.week_start_day),
        preferences.show_weekends
      )

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
