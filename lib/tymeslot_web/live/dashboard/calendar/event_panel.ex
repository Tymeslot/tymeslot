defmodule TymeslotWeb.Dashboard.Calendar.EventPanel do
  @moduledoc """
  The side panel that opens beside the grid to change an event
  (`calendar:edit`, from the preview's Edit button or E on a focused event).

  It takes a 22rem column to the right of the grid inside the surface's
  flex row, so the grid narrows rather than being covered; the hook lays the
  grid out again when it opens or closes (`calendar:panel`) and moves focus
  to the element marked `data-panel-focus` on open, back to the event on
  close. Escape inside the panel closes it (the hook reads it, `closePanelOnEscape`).

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
  alias TymeslotWeb.Dashboard.Calendar.PanelFields
  alias TymeslotWeb.Dashboard.Calendar.PanelStatus
  alias TymeslotWeb.Dashboard.Calendar.PanelTiming
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
          errors={List.wrap(@panel.errors["title"])}
          data-panel-focus={@editable && "true"}
          data-panel-field="title"
          phx-blur="panel:title"
          phx-keydown="panel:title"
          phx-key="Enter"
          phx-target={@surface}
        />
        <PanelTiming.timing_fields
          :if={timed_or_all_day?(@event)}
          timing={PanelTiming.fields(@event, @context.timezone)}
          disabled={!@movable}
          error={@panel.errors["timing"]}
          target={@surface}
        />
        <%!-- Repeat (Task 19) goes here. --%>
        <%!-- Calendar (Task 20) goes here. --%>
        <PanelFields.busy_free :if={@movable} free={free?(@event)} target={@surface} />
        <.input
          id="calendar-panel-location"
          name="location"
          type="text"
          label={dgettext("dashboard_calendar", "Place")}
          placeholder={dgettext("dashboard_calendar", "Add a place or room")}
          value={Map.get(@event, :location) || ""}
          disabled={!@editable}
          errors={List.wrap(@panel.errors["location"])}
          data-panel-field="location"
          phx-blur="panel:location"
          phx-keydown="panel:location"
          phx-key="Enter"
          phx-target={@surface}
        />
        <%!-- Video (Task 21) and guests (Task 22) go here. --%>
        <PanelFields.reminder_field
          reminders={Map.get(@event, :reminders) || []}
          disabled={!@editable}
          target={@surface}
        />
        <.input
          id="calendar-panel-notes"
          name="description"
          type="textarea"
          rows={4}
          label={dgettext("dashboard_calendar", "Notes")}
          placeholder={dgettext("dashboard_calendar", "Agenda, links, anything else")}
          value={Map.get(@event, :description) || ""}
          disabled={!@editable}
          errors={List.wrap(@panel.errors["notes"])}
          data-panel-field="notes"
          phx-blur="panel:notes"
          phx-target={@surface}
        />
      </div>
    </aside>
    """
  end

  defp title_value(%{kind: :booking} = booking), do: EventPayload.title(booking)
  defp title_value(event), do: Map.get(event, :summary) || ""

  defp timed_or_all_day?(%{all_day: true, start_date: %Date{}}), do: true
  defp timed_or_all_day?(%{start_at: %DateTime{}, end_at: %DateTime{}}), do: true
  defp timed_or_all_day?(_event), do: false

  defp free?(event), do: Map.get(event, :transparency) == "transparent"

  defp status_class({:waiting, _account}), do: "text-amber-800"
  defp status_class({:failed, _reason}), do: "text-red-700"
  defp status_class(:saving), do: "text-tymeslot-600"
  defp status_class(_idle_saved_or_read_only), do: "text-tymeslot-500"
end
