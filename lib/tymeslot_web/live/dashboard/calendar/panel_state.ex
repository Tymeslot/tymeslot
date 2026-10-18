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

  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload

  @type socket :: Phoenix.LiveView.Socket.t()

  # The series questions the panel asks (see `SeriesScopeModal`), dropped
  # when it closes.
  @panel_prompts [:panel, :panel_repeat]

  @doc """
  Opens the panel on the loaded event `id`, closing the preview and any
  menu, and tells the hook the grid narrowed. An id that is not a loaded
  event (another organiser's, or one outside the window) opens nothing.
  """
  @spec open_edit(socket(), String.t()) :: socket()
  def open_edit(socket, id) do
    case Map.fetch(socket.assigns.events_by_id, id) do
      {:ok, event} ->
        socket
        |> assign(panel: new_panel(socket.assigns, event), preview: nil, open_menu: nil)
        |> push_event("calendar:panel", %{open: true})

      :error ->
        socket
    end
  end

  @doc """
  Closes the panel and hands focus back to its event. A series question
  the panel was waiting on goes with it; nothing was written for it.
  """
  @spec close(socket()) :: socket()
  def close(%{assigns: %{panel: %{event_id: id}}} = socket) do
    socket
    |> assign(panel: nil, series_prompt: without_panel_prompt(socket.assigns.series_prompt))
    |> push_event("calendar:panel", %{open: false, focus: id})
  end

  def close(socket), do: socket

  @doc "Closes the panel without moving focus, for the preview taking its place."
  @spec give_way(socket()) :: socket()
  def give_way(%{assigns: %{panel: %{}}} = socket) do
    socket
    |> assign(panel: nil, series_prompt: without_panel_prompt(socket.assigns.series_prompt))
    |> push_event("calendar:panel", %{open: false})
  end

  def give_way(socket), do: socket

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
      integrations: assigns.integrations
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

  defp new_panel(assigns, event) do
    %{
      mode: :edit,
      event_id: EventPayload.id(event),
      event: event,
      draft: nil,
      draft_id: nil,
      form: %{},
      scope: nil,
      opened_with: event,
      status: opening_status(assigns.integrations, event),
      writes: [],
      errors: %{},
      repeat: %{custom_open: false, draft: nil, version: 0},
      calendar_version: 0,
      video_version: 0
    }
  end

  defp opening_status(integrations, event),
    do: if(EditGuard.editable?(integrations, event), do: :idle, else: :read_only)

  defp without_panel_prompt(%{kind: kind}) when kind in @panel_prompts, do: nil
  defp without_panel_prompt(prompt), do: prompt
end
