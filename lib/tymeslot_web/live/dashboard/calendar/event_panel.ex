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

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias TymeslotWeb.Dashboard.Calendar.PanelActions
  alias TymeslotWeb.Dashboard.Calendar.PanelCalendarField
  alias TymeslotWeb.Dashboard.Calendar.PanelFields
  alias TymeslotWeb.Dashboard.Calendar.PanelGuests
  alias TymeslotWeb.Dashboard.Calendar.PanelGuestsField
  alias TymeslotWeb.Dashboard.Calendar.PanelNewForm
  alias TymeslotWeb.Dashboard.Calendar.PanelRepeat
  alias TymeslotWeb.Dashboard.Calendar.PanelStatus
  alias TymeslotWeb.Dashboard.Calendar.PanelTiming
  alias TymeslotWeb.Dashboard.Calendar.PanelVideoField
  alias TymeslotWeb.Dashboard.Calendar.Transfer
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  # The New event state draws the draft's form: there is no event to read
  # a guard or a repeat rule from, and every field can be changed.
  @impl Phoenix.LiveComponent
  def update(%{panel: %{mode: :new}} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       event_id: nil,
       editable: true,
       movable: true,
       read_only_reason: nil,
       booking_copy: false,
       booking_copy_for: nil,
       emails_guests: false,
       untold: false
     )}
  end

  def update(%{panel: panel, event: event, context: context} = assigns, socket) do
    socket =
      if socket.assigns[:event_id] == panel.event_id,
        do: socket,
        else: opened(socket, event, context)

    socket =
      if socket.assigns[:event] == event,
        do: socket,
        else: assign(socket, :repeat, PanelRepeat.field(event, context.timezone))

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:event_id, panel.event_id)
     |> assign_booking_copy()
     |> assign_untold()}
  end

  # Asked on every update the panel's event or its starting point changes;
  # the diff is pure, no query. Never drawn for an event whose guests the
  # organiser may not email (`emails_guests`).
  defp assign_untold(socket),
    do:
      assign(socket,
        untold:
          socket.assigns.emails_guests and
            PanelGuests.untold?(socket.assigns.panel[:opened_with], socket.assigns[:event])
      )

  # Whether the event is the calendar copy of a booking costs a query, so it
  # is asked once per event the panel shows, not on every update.
  defp assign_booking_copy(%{assigns: %{event: %{} = event}} = socket) do
    id = EventPayload.id(event)

    if socket.assigns[:booking_copy_for] == id,
      do: socket,
      else: assign(socket, booking_copy: booking_copy?(event), booking_copy_for: id)
  end

  defp assign_booking_copy(socket), do: assign(socket, booking_copy: false, booking_copy_for: nil)

  defp booking_copy?(%{calendar_integration_id: integration_id} = event)
       when is_integer(integration_id),
       do: Changes.ensure_video_changeable(event) != :ok

  defp booking_copy?(_event), do: false

  # Read once per event: whether it can be changed, whether its timing can
  # (a booking's calendar copy keeps the booking's time), and whether the
  # organiser may email its guests: invite, remove, tell (they organise
  # it; a query or two).
  defp opened(socket, event, %{integrations: integrations} = context) do
    writable = EditGuard.writable(integrations, event)

    assign(socket,
      editable: writable == :ok,
      movable: EditGuard.movable?(integrations, event),
      read_only_reason: read_only_reason(writable),
      emails_guests: EditGuard.guest_update(context.user_id, integrations, event) == :ok
    )
  end

  defp read_only_reason(:ok), do: nil
  defp read_only_reason(refusal), do: refusal |> CalendarEditMessages.refusal() |> elem(1)

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <aside
      id="calendar-panel"
      class="cal-panel flex flex-col"
      aria-label={dgettext("dashboard_calendar_editing", "Event details")}
    >
      <div class="cal-panel-head flex items-center gap-2 border-b border-tymeslot-100 px-4 py-2">
        <h2
          :if={@panel.mode == :new}
          id="calendar-panel-heading"
          class="shrink-0 text-token-sm font-semibold text-tymeslot-900"
        >
          {dgettext("dashboard_calendar_editing", "New event")}
        </h2>
        <p
          id="calendar-panel-status"
          role="status"
          class={["min-w-0 flex-1 text-token-xs", status_class(@panel.status)]}
        >
          {status_text(@panel)}
        </p>
        <.icon_button
          id="calendar-panel-close"
          icon="hero-x-mark"
          size={:sm}
          label={dgettext("dashboard_calendar_editing", "Close details")}
          data-panel-focus={!@editable && "true"}
          phx-click="panel:close"
          phx-target={@surface}
        />
      </div>
      <PanelGuestsField.untold_note
        :if={@panel.mode == :edit && @untold}
        saving={@panel.status == :saving}
        surface={@surface}
      />
      <div
        :if={@panel.mode == :edit}
        class="min-h-0 flex-1 space-y-4 overflow-y-auto px-4 py-4"
      >
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
          label={dgettext("dashboard_calendar_editing", "Title")}
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
        <PanelRepeat.repeat_field
          repeat={@repeat}
          disabled={!@editable}
          custom_open={@panel.repeat.custom_open}
          draft={@panel.repeat.draft}
          version={@panel.repeat.version}
          target={@surface}
        />
        <form
          :if={@event}
          novalidate
          id="calendar-panel-calendar-form"
          phx-change="panel:transfer"
          phx-target={@surface}
        >
          <PanelCalendarField.calendar_field
            choices={@calendar_choices}
            value={Transfer.calendar_key(@event, @context.integrations)}
            disabled={@moving or not @editable}
            version={@panel.calendar_version}
          />
        </form>
        <PanelFields.busy_free :if={@movable} free={free?(@event)} target={@surface} />
        <.input
          id="calendar-panel-location"
          name="location"
          type="text"
          label={dgettext("dashboard_calendar_editing", "Place")}
          placeholder={dgettext("dashboard_calendar_editing", "Add a place or room")}
          value={Map.get(@event, :location) || ""}
          disabled={!@editable}
          errors={List.wrap(@panel.errors["location"])}
          data-panel-field="location"
          phx-blur="panel:location"
          phx-keydown="panel:location"
          phx-key="Enter"
          phx-target={@surface}
        />
        <PanelVideoField.video_row
          :if={@event}
          editable={@editable}
          event={@event}
          video_integrations={@video_integrations}
          booking_copy={@booking_copy}
          saving={@panel.status == :saving}
          version={@panel.video_version}
          surface={@surface}
        />
        <PanelGuestsField.guests_row
          :if={@event && @editable}
          guests={PanelGuests.of(@event)}
          organiser={@emails_guests}
          form_key={@guest_form_key}
          repeating={
            is_binary(Map.get(@event, :recurring_event_id)) or
              is_binary(Map.get(@event, :recurrence_rule))
          }
          surface={@surface}
        />
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
          label={dgettext("dashboard_calendar_editing", "Notes")}
          placeholder={dgettext("dashboard_calendar_editing", "Agenda, links, anything else")}
          value={Map.get(@event, :description) || ""}
          disabled={!@editable}
          errors={List.wrap(@panel.errors["notes"])}
          data-panel-field="notes"
          phx-blur="panel:notes"
          phx-target={@surface}
        />
        <PanelActions.edit_actions :if={@event && @editable} movable={@movable} surface={@surface} />
      </div>
      <div :if={@panel.mode == :new} class="min-h-0 flex-1 overflow-y-auto px-4 py-4">
        <PanelNewForm.new_form
          values={@panel.form}
          saving={@panel.status == :saving}
          calendar_choices={@calendar_choices}
          video_integrations={@video_integrations}
          guest_form_key={@guest_form_key}
          surface={@surface}
          group_allowed={@group_allowed}
          venues={Map.get(@panel, :venues, [])}
          timezone={@timezone}
        />
      </div>
    </aside>
    """
  end

  defp status_text(%{mode: :new, status: :idle}),
    do: dgettext("dashboard_calendar_editing", "Nothing is saved until you create it")

  defp status_text(%{status: status}), do: PanelStatus.text(status)

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
