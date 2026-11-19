defmodule TymeslotWeb.Dashboard.Calendar.PanelState do
  @moduledoc """
  The side panel's state on the calendar surface, the `panel` assign:
  opening it on an event, closing it, and what it holds. The panel and the
  preview are never open together: opening one closes the other.

  Every panel event is handled on the surface (`PanelEvents`), so what the
  panel shows beyond its event lives here too: a field's inline error
  (`errors`, by field) and the custom repeat editor's state (`repeat`).

  `panel` keeps the latest version of its event (`:event`), so a window
  reload that drops the event (a series write empties its cached rows) does
  not close the panel; the loaded event wins whenever it is there
  (`current_event/1`).
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias TymeslotWeb.Dashboard.Calendar.PanelGuests
  alias TymeslotWeb.Dashboard.Calendar.Preview
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData

  @type socket :: Phoenix.LiveView.Socket.t()

  # The series questions the panel asks (see `SeriesScopeModal`), dropped
  # when it closes.
  @panel_prompts [:panel, :panel_repeat]

  @doc "Whether `prompt` is a series question the panel asked."
  @spec panel_prompt?(map() | nil) :: boolean()
  def panel_prompt?(%{kind: kind}), do: kind in @panel_prompts
  def panel_prompt?(_prompt), do: false

  @doc """
  Opens the panel on the loaded event `id`, closing the preview and any
  menu, and tells the hook the grid narrowed. An id that is not a loaded
  event (another organiser's, or one outside the window) opens nothing.
  """
  @spec open_edit(socket(), String.t()) :: socket()
  def open_edit(socket, id) do
    case Map.fetch(socket.assigns.events_by_id, id) do
      {:ok, event} ->
        # A previewed occurrence of a series no sync has cached yet opens
        # the series, which is the only part of it there is to change.
        event = CalendarGrid.preview_series(event)
        id = EventPayload.id(event)
        held_until = held_until(event)

        without_draft(socket, fn socket ->
          socket
          |> drop_prompts()
          |> assign(
            panel: new_panel(socket.assigns, event, held_until),
            preview: nil,
            open_menu: nil
          )
          |> PanelGuests.forget_held_from(id, held_until)
          |> PanelGuests.watch_hold(id, held_until)
          |> push_event("calendar:panel", %{open: true})
        end)

      :error ->
        socket
    end
  end

  @doc """
  Opens the preview of the loaded event `id` in the panel's place, as the
  grid's click does; `socket` unchanged for an id that is not loaded.
  """
  @spec open_preview(socket(), String.t()) :: socket()
  def open_preview(socket, id) do
    case Map.fetch(socket.assigns.events_by_id, id) do
      {:ok, event} ->
        preview = Preview.build(event, Preview.context(socket.assigns))
        socket |> give_way() |> assign(preview: preview, open_menu: nil)

      :error ->
        socket
    end
  end

  @doc """
  Closes the panel and hands focus back to its event. A series question
  the panel was waiting on goes with it; nothing was written for it. A New
  event panel's draft is dropped from the grid (`calendar:draft-cleared`,
  then the payload); one a plain create is already saving is the create's.
  """
  @spec close(socket()) :: socket()
  def close(%{assigns: %{panel: %{event_id: id}}} = socket) do
    without_draft(socket, fn socket ->
      socket
      |> drop_prompts()
      |> assign(panel: nil)
      |> push_event("calendar:panel", %{open: false, focus: id})
    end)
  end

  def close(socket), do: socket

  @doc "Closes the panel when it is open on the event `id` names."
  @spec close_on(socket(), String.t()) :: socket()
  def close_on(%{assigns: %{panel: %{event_id: id}}} = socket, id), do: close(socket)
  def close_on(socket, _id), do: socket

  @doc """
  Forgets the writes the panel was waiting on, for a surface that missed
  their answers (revived after the organiser left the calendar): a header
  still saving goes back to its resting line rather than saving for ever. A
  "New event" panel whose create was in flight closes, as the create's
  answer is lost; the reload shows the event if it was made.
  """
  @spec forget_writes(socket()) :: socket()
  def forget_writes(%{assigns: %{panel: %{mode: :new, status: :saving}}} = socket),
    do: close(socket)

  def forget_writes(socket),
    do: update(socket, &%{&1 | writes: [], status: settled_status(&1.status)})

  defp settled_status(:saving), do: :idle
  defp settled_status(status), do: status

  @doc "Closes the panel without moving focus, for the preview taking its place."
  @spec give_way(socket()) :: socket()
  def give_way(%{assigns: %{panel: %{}}} = socket) do
    without_draft(socket, fn socket ->
      socket
      |> drop_prompts()
      |> assign(panel: nil)
      |> push_event("calendar:panel", %{open: false})
    end)
  end

  def give_way(socket), do: socket

  @doc """
  The event `id` as the surface holds it: a loaded event, or the panel's own
  when the panel is open on it but the window does not hold it (the series
  of a previewed occurrence, cached weeks before the visible ones, or an
  event a reload has dropped).
  """
  @spec fetch_event(map(), String.t()) :: {:ok, map()} | :error
  def fetch_event(%{events_by_id: by_id} = assigns, id) do
    case {Map.fetch(by_id, id), Map.get(assigns, :panel)} do
      {{:ok, _event} = found, _panel} -> found
      {:error, %{event_id: ^id, event: %{} = event}} -> {:ok, event}
      {:error, _other} -> :error
    end
  end

  @doc "The panel's event as the surface holds it now; `nil` with no panel open."
  @spec current_event(map()) :: map() | nil
  def current_event(%{panel: %{event_id: id, event: event}, events_by_id: by_id}),
    do: Map.get(by_id, id, event)

  def current_event(_assigns), do: nil

  @doc "What the panel reads from the surface besides its event."
  @spec context(map()) :: map()
  def context(assigns),
    do: %{
      timezone: assigns.timezone,
      time_format: assigns.time_format,
      integrations: assigns.integrations,
      locked_uids: Map.get(assigns, :locked_uids, MapSet.new()),
      colour_overrides: Map.get(assigns, :colour_overrides, %{}),
      user_id: assigns.current_user.id
    }

  @doc "Applies `fun` to the open panel; with no panel open, nothing."
  @spec update(socket(), (map() -> map())) :: socket()
  def update(%{assigns: %{panel: %{} = panel}} = socket, fun),
    do: assign(socket, :panel, fun.(panel))

  def update(socket, _fun), do: socket

  @doc "Shows `message` under the field `field`, or clears it for `nil`."
  @spec put_error(socket(), String.t(), String.t() | nil) :: socket()
  def put_error(socket, field, nil),
    do: update(socket, &%{&1 | errors: Map.delete(&1.errors, field)})

  def put_error(socket, field, message),
    do: update(socket, &%{&1 | errors: Map.put(&1.errors, field, message)})

  # Leaving a New event panel takes its draft off the hook's grid at once (the
  # hook holds it even when the domain refused it), and the payload that
  # follows no longer carries it. A plain create that is saving owns the
  # draft: `PanelNew` hands it to `pending_creates` and clears the panel's
  # `draft`. A meeting being saved keeps its draft in the panel, as nothing
  # else draws it, so leaving drops it like any other; the reload after the
  # booking shows the meeting if it was made.
  defp without_draft(
         %{assigns: %{panel: %{mode: :new, status: :saving, draft: nil}}} = socket,
         leave
       ),
       do: leave.(socket)

  defp without_draft(%{assigns: %{panel: %{mode: :new, draft_id: id}}} = socket, leave) do
    socket
    |> push_event("calendar:draft-cleared", %{draft: id})
    |> leave.()
    |> SurfaceData.push_events(false)
  end

  defp without_draft(socket, leave), do: leave.(socket)

  defp new_panel(assigns, event, held_until) do
    %{
      mode: :edit,
      event_id: EventPayload.id(event),
      event: event,
      draft: nil,
      draft_id: nil,
      form: %{},
      scope: nil,
      opened_with: Map.get(assigns.untold_moves, EventPayload.id(event), event),
      guests_pending: held_until != nil,
      held_until: nil,
      hold_watch: nil,
      status: opening_status(assigns, event),
      writes: [],
      errors: %{},
      repeat: %{custom_open: false, draft: nil, version: 0},
      calendar_version: 0,
      video_version: 0
    }
  end

  # An update "Tell guests" sent is held a while before it goes out; the
  # panel offers to cancel it meanwhile, until it is due. Only an event
  # with guests can have one, so the others cost no query.
  defp held_until(event) do
    if event |> Map.get(:attendees) |> List.wrap() |> Enum.any?(),
      do: Changes.guest_update_held_until(event)
  end

  defp opening_status(assigns, event) do
    locked = Map.get(assigns, :locked_uids, MapSet.new())

    if EditGuard.drawn_writable(assigns.integrations, locked, event) == :ok,
      do: :idle,
      else: :read_only
  end

  # What the panel asked about its event goes when the panel leaves that
  # event: the series question, the question about moving a series to another
  # calendar, the one about removing a guest and the one about discarding a
  # draft's guests (the panel is the only place they are asked), since an answer would act on an event no longer shown.
  # The grid's own series question (a drag or resize) stays.
  defp drop_prompts(socket) do
    assign(socket,
      series_prompt:
        if(panel_prompt?(socket.assigns.series_prompt),
          do: nil,
          else: socket.assigns.series_prompt
        ),
      series_move_prompt: nil,
      remove_guest_prompt: nil,
      discard_draft_prompt: nil
    )
  end
end
