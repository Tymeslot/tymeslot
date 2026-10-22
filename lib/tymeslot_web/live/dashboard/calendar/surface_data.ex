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

  import Phoenix.Component, only: [assign: 2, assign: 3, changed?: 2]
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3]

  alias Tymeslot.Availability.Bookability
  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.CalendarDirectory
  alias Tymeslot.CalendarGrid.ColourTokens
  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.EventWindow
  alias Tymeslot.CalendarGrid.LayerPreferences
  alias Tymeslot.CalendarGrid.Period
  alias Tymeslot.CalendarGrid.WorkingHours
  alias Tymeslot.CalendarGrid.WriteQueue
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesSchema
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Profiles
  alias TymeslotWeb.Dashboard.Calendar.AgendaLoader
  alias TymeslotWeb.Dashboard.Calendar.BookableLayer
  alias TymeslotWeb.Dashboard.Calendar.Deletion
  alias TymeslotWeb.Dashboard.Calendar.LastView
  alias TymeslotWeb.Dashboard.Calendar.PanelState
  alias TymeslotWeb.Dashboard.Calendar.PendingDeletes
  alias TymeslotWeb.Dashboard.Calendar.PowerSettings
  alias TymeslotWeb.Dashboard.Calendar.Preview
  alias TymeslotWeb.Dashboard.Calendar.ReminderFeed
  alias TymeslotWeb.Dashboard.Calendar.SyncStatus
  alias TymeslotWeb.Dashboard.Calendar.UndoStack
  alias TymeslotWeb.Dashboard.Calendar.Visibility
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
      video_integrations: [],
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
      agenda_through: nil,
      rail_open: true,
      viewport: :wide,
      viewport_reported: false,
      open_menu: nil,
      focus_return: false,
      preview: nil,
      panel: nil,
      event_writes: WriteQueue.new(),
      writes_adopted_after: nil,
      undo: UndoStack.new(),
      tab_id: nil,
      undoing: %{},
      toast: nil,
      series_prompt: nil,
      delete_prompt: nil,
      pending_deletes: %{},
      pending_creates: %{},
      created_drafts: [],
      syncing_ids: MapSet.new(),
      failure_counts: %{},
      sync_refs: %{},
      transfer: nil,
      series_move_prompt: nil,
      remove_guest_prompt: nil,
      guest_form_key: 0,
      bookable_types: [],
      bookability: %{},
      bookable: nil,
      bookable_load: :idle,
      bookable_pending: false
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
        |> ReminderFeed.refresh()
        |> Writes.adopt()
        |> SyncStatus.load_persisted()
        |> SyncStatus.refresh_stale()
        |> assign(:ready?, true)

      true ->
        socket |> adopt_if_revived() |> follow()
    end
  end

  @doc """
  Loads preferences, calendars, colours, hidden choices, calendar sets and
  working hours, and resolves what is hidden (see `Visibility.resolve/1`).
  """
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
      video_integrations: Video.list_active_integrations(user_id),
      integration_tokens: ColourTokens.for_integrations(integrations),
      calendar_tokens: ColourTokens.for_calendars(integrations, appearances),
      manual_hidden_keys: Appearance.hidden_keys(appearances),
      working_hours: WorkingHours.for_profile(socket.assigns[:profile]),
      bookable_types: LayerPreferences.meeting_types(user_id),
      bookability: Bookability.for_user(user_id)
    )
    |> Visibility.load_sets(preferences)
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

  @doc """
  Sets the period from the URL (or the defaults) and resets per-period UI.
  With `keep_open?: true` the preview and the open sheet stay: a rotation
  changes the view, not what the organiser was looking at.
  """
  @spec apply_params(socket(), keyword()) :: socket()
  def apply_params(socket, opts \\ []) do
    {view, date} = target(socket.assigns)

    socket =
      assign(socket,
        view: view,
        date: date,
        mini_cursor: Date.beginning_of_month(date),
        agenda_through: nil
      )

    if Keyword.get(opts, :keep_open?, false),
      do: socket,
      else: assign(socket, preview: nil, open_menu: nil)
  end

  @doc "Loads the events for the period plus one period either side (an agenda: as far as it has grown). The bookable layer is loaded for the same window (see BookableLayer)."
  @spec load_window(socket()) :: socket()
  def load_window(socket) do
    window = window_for(socket.assigns)

    socket
    |> assign(window: window, window_events: list_events(socket.assigns, window))
    |> filter_events()
    |> BookableLayer.load()
  end

  @doc """
  The organiser's events for `range`, unfiltered: the one query behind
  every window, an agenda's next chunk included (see `AgendaLoader`).
  """
  @spec list_events(map(), Date.Range.t()) :: [map()]
  def list_events(%{current_user: user, timezone: timezone, integrations: integrations}, range) do
    {start_dt, end_dt} = EventWindow.utc_range(range.first, range.last, timezone)

    # Bookings are drawn as themselves rather than as their calendar copies,
    # and requests that expired unanswered are drawn too (see `EventWindow`).
    EventWindow.list_events(user.id, integrations, start_dt, end_dt, include_expired: true)
  end

  @doc "`events` without hidden calendars and accounts, or deletes still waiting for their undo."
  @spec visible(map(), [map()]) :: [map()]
  def visible(assigns, events) do
    events
    |> EventWindow.reject_hidden(assigns.hidden_integration_ids, assigns.hidden_calendar_keys)
    |> PendingDeletes.reject(assigns.pending_deletes)
  end

  @doc """
  Follows the period the URL, the stored default and the viewport now name,
  pushing it to the hook: `calendar:period` when the loaded window holds it,
  otherwise the reloaded window.

  The same period again only closes the date picker, and only when the URL
  changed: a parent render for another prop (the clock or focus mode, both
  switched from the open display options) keeps the menu open. A different
  day whose window is the one already loaded (another day of the visible
  week) updates the title and range but needs no query: the hook already
  holds the events.
  Either way the hook still hears which period the URL settled on
  (`calendar:period`), because it holds a navigation as pending until the
  server confirms it and follows nothing else (not even Back) meanwhile.
  """
  @spec follow(socket(), keyword()) :: socket()
  def follow(socket, opts \\ []) do
    socket = assign_clock(socket)
    %{view: view, date: date, window: loaded} = socket.assigns

    case target(socket.assigns) do
      {^view, ^date} ->
        socket = if changed?(socket, :params), do: assign(socket, :open_menu, nil), else: socket
        push_period(socket)

      _other ->
        socket = apply_params(socket, opts)
        # A resize or rotation (`keep_open?`) is not a choice of view.
        socket = if opts[:keep_open?], do: socket, else: LastView.remember(socket)

        if window_for(socket.assigns) == loaded,
          do: push_period(socket),
          else: socket |> load_window() |> push_events(false)
    end
  end

  @doc """
  The period the surface shows: the URL's view (or the stored default) as
  the viewport shows it (a week is three days on a phone), around the URL's
  date (or today).
  """
  @spec target(map()) :: {Period.view(), Date.t()}
  def target(%{params: params, preferences: preferences, today: today} = assigns) do
    params = params || %{}

    view =
      params["view"]
      |> Period.parse_view(Period.default_view(preferences.default_view))
      |> Period.for_viewport(Map.get(assigns, :viewport, :wide))

    {view, Period.parse_date(params["date"], today)}
  end

  # Applies the hidden choices to the window's unfiltered events, so a toggle
  # needs no query.
  defp filter_events(socket) do
    events = visible(socket.assigns, socket.assigns.window_events)

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

    Map.merge(
      %{
        week_start: Atom.to_string(Period.week_start(preferences.week_start_day)),
        show_weekends: preferences.show_weekends,
        density: preferences.density,
        fold_night: preferences.fold_night,
        time_format: assigns.time_format,
        working_hours: assigns.working_hours,
        calendars: CalendarDirectory.choices(assigns.accounts),
        default_calendar: CalendarDirectory.default_calendar(assigns.integrations),
        # Accounts without a writable calendar: quick create says they are read-only.
        has_accounts: assigns.accounts != [],
        # The meeting types quick create can open for booking (Task 9's list:
        # active, unarchived, `%{id, name, duration}`); `duration` keeps an
        # opening at least one meeting long.
        meeting_types: assigns.bookable_types
      },
      PowerSettings.settings(assigns)
    )
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
  (no window query; the reminder feed is rebuilt) and push with a cache reset.
  """
  @spec refresh(socket()) :: socket()
  def refresh(socket),
    do:
      socket
      |> assign_accounts()
      |> filter_events()
      |> ReminderFeed.assign_feed()
      |> push_events(true)

  @doc """
  After a sync or an outside change, push with a cache reset. `:full` reloads
  the context (calendars, colours, preferences) as well as the events;
  `:events` reloads the events alone.
  """
  @spec reload(socket(), :full | :events) :: socket()
  def reload(socket, scope \\ :full)
  def reload(socket, :full), do: socket |> load_context() |> reload(:events)

  def reload(socket, :events),
    do:
      socket
      |> Deletion.prune()
      |> load_window()
      |> ReminderFeed.assign_feed()
      |> push_events(true)

  @doc """
  Records a saved preference in the assigns. The upsert's return value is not
  used for this: it is built from the attributes passed, so its other fields
  are defaults rather than what the row holds.
  """
  @spec put_preference(socket(), atom(), term()) :: socket()
  def put_preference(socket, key, value),
    do: assign(socket, :preferences, Map.put(socket.assigns.preferences, key, value))

  # LiveView revives a surface rendered again before the browser confirmed
  # its removal (the organiser left the calendar and came straight back). It
  # takes back the queue its guardian has been driving since, as a surface
  # mounted afresh does, and reloads what those writes changed. The gate is
  # `calendar_left`, which counts departures; the surface remembers the
  # count its queue was adopted at.
  defp adopt_if_revived(socket) do
    if socket.assigns[:calendar_left] == socket.assigns.writes_adopted_after,
      do: socket,
      else: socket |> Writes.adopt() |> forget_unanswered() |> reload(:events)
  end

  # While detached the guardian drove the writes, so their answers never
  # reached the surface: `Manipulation.settled/2` and `forget/2` never ran
  # for the undos in flight, the panel never heard about its own writes, and
  # a change whose write failed meanwhile would still sit on the undo stack.
  # Every change that names a write is dropped, as nothing tells which
  # of them landed. Nor did the answer to a move or a create in flight
  # reach it (`CalendarRouting` routes them to a surface on screen only),
  # so the move is no longer waited for and the creates' drafts go; the
  # reload that follows shows whatever landed.
  defp forget_unanswered(socket) do
    socket
    |> clear_pending_drafts()
    |> assign(
      undoing: %{},
      undo: UndoStack.drop(socket.assigns.undo, &Map.has_key?(&1, :ref)),
      transfer: nil,
      pending_creates: %{}
    )
    |> PanelState.forget_writes()
  end

  defp clear_pending_drafts(socket),
    do:
      Enum.reduce(Map.keys(socket.assigns.pending_creates), socket, fn draft, socket ->
        push_event(socket, "calendar:draft-cleared", %{draft: draft})
      end)

  defp push_period(%{assigns: %{view: view, date: date}} = socket),
    do:
      push_event(socket, "calendar:period", %{
        view: Atom.to_string(view),
        date: Date.to_iso8601(date)
      })

  defp window_for(%{view: view, date: date, preferences: preferences} = assigns) do
    window =
      Period.window(
        view,
        date,
        Period.week_start(preferences.week_start_day),
        preferences.show_weekends
      )

    AgendaLoader.extend_window(assigns, window)
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
