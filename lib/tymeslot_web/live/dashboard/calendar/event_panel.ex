defmodule TymeslotWeb.Dashboard.Calendar.EventPanel do
  @moduledoc """
  The side panel that opens beside the grid to change an event
  (`calendar:edit`, from the preview's Edit button or E on a focused event).

  It takes a 22rem column to the right of the grid inside the surface's
  flex row, so the grid narrows rather than being covered; the hook lays the
  grid out again when it opens or closes (`calendar:panel`) and moves focus
  to the element marked `data-panel-focus` on open, back to the event on
  close. Escape inside the panel closes it.

  The component only draws. Its controls send `panel:<name>` events to the
  surface (`surface` is the surface's target), which handles them
  (`PanelEvents`), keeps the panel's state (`PanelState`) and writes through
  `Calendar.Writes`. What it reads once per event is whether the event can
  be changed: an event the organiser cannot change (a booking, an event on
  a calendar that is read only) opens read only, saying why, with every
  field disabled, and focus goes to the close button.
  """

  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias TymeslotWeb.Dashboard.Calendar.PanelStatus
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @impl Phoenix.LiveComponent
  def update(%{panel: panel, event: event, context: context} = assigns, socket) do
    socket =
      if socket.assigns[:event_id] == panel.event_id,
        do: socket,
        else: opened(socket, event, context.integrations)

    {:ok, socket |> assign(assigns) |> assign(:event_id, panel.event_id)}
  end

  # Read once per event: whether it can be changed, and whether its timing
  # can (a booking's calendar copy keeps the booking's time).
  defp opened(socket, event, integrations) do
    writable = EditGuard.writable(integrations, event)

    assign(socket,
      editable: writable == :ok,
      movable: EditGuard.movable?(integrations, event),
      read_only_reason: read_only_reason(writable)
    )
  end

  defp read_only_reason(:ok), do: nil
  defp read_only_reason(refusal), do: refusal |> CalendarEditMessages.refusal() |> elem(1)

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <aside
      id="calendar-panel"
      class="cal-panel flex w-88 shrink-0 flex-col border-l border-tymeslot-200 bg-white"
      aria-label={dgettext("dashboard_calendar", "Event details")}
      phx-keydown="panel:close"
      phx-key="Escape"
      phx-target={@surface}
    >
      <div class="flex items-center gap-2 border-b border-tymeslot-100 px-4 py-2">
        <p
          id="calendar-panel-status"
          role="status"
          class={["min-w-0 flex-1 text-token-xs", status_class(@panel.status)]}
        >
          {PanelStatus.text(@panel.status)}
        </p>
        <.icon_button
          id="calendar-panel-close"
          icon="hero-x-mark"
          size={:sm}
          label={dgettext("dashboard_calendar", "Close details")}
          data-panel-focus={!@editable && "true"}
          phx-click="panel:close"
          phx-target={@surface}
        />
      </div>
      <div class="min-h-0 flex-1 space-y-4 overflow-y-auto px-4 py-4">
        <p
          :if={@read_only_reason}
          id="calendar-panel-read-only"
          class="text-token-sm text-tymeslot-600"
        >
          {@read_only_reason}
        </p>
        <.input
          id="calendar-panel-title"
          name="title"
          type="text"
          label={dgettext("dashboard_calendar", "Title")}
          value={title_value(@event)}
          disabled={!@editable}
          data-panel-focus={@editable && "true"}
        />
      </div>
    </aside>
    """
  end

  defp title_value(%{kind: :booking} = booking), do: EventPayload.title(booking)
  defp title_value(event), do: Map.get(event, :summary) || ""

  defp status_class({:waiting, _account}), do: "text-amber-800"
  defp status_class({:failed, _reason}), do: "text-red-700"
  defp status_class(:saving), do: "text-tymeslot-600"
  defp status_class(_idle_saved_or_read_only), do: "text-tymeslot-500"
end
