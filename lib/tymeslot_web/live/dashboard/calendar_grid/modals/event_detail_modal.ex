defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.EventDetailModal do
  @moduledoc "Event detail/edit modal for viewing and editing calendar events."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias TymeslotWeb.Components.Dashboard.ColourSwatches
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.AttendeeEditor
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.CalendarPicker
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrenceEditor
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RemindersEditor
  alias TymeslotWeb.Dashboard.CalendarGrid.VideoPicker
  alias TymeslotWeb.Dashboard.DashboardFormat

  attr :selected_event, :map, required: true
  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :calendar_colors, :map, required: true
  attr :user_timezone, :string, required: true
  attr :time_format, :string, default: "12h"
  attr :myself, :any, required: true
  attr :editable, :boolean, default: false

  attr :time_locked, :boolean,
    default: false,
    doc:
      "A live seat is held on this event's meeting, so its time, attendees and deletion are not editable here."

  attr :attendee_input, :string, default: ""
  attr :pending_attendees, :list, default: []
  attr :video_integrations, :list, default: []
  attr :pending_notification, :boolean, default: false

  @spec event_detail_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def event_detail_modal(assigns) do
    assigns = assign(assigns, :attendees, attendees(assigns.selected_event))

    ~H"""
    <.modal
      id="event-detail-modal"
      show={true}
      on_cancel={JS.push("close_event_detail", target: @myself)}
      size={:medium}
      aria_label={@selected_event.summary || dgettext("dashboard_calendar_events", "Event details")}
    >
      <%!-- Pending-notification banner --%>
      <div
        :if={@pending_notification}
        class="rounded-token-lg bg-turquoise-50 border border-turquoise-200 p-2 mb-3 flex items-center justify-between"
      >
        <span class="text-token-sm text-turquoise-900">
          {dgettext("dashboard_calendar_events", "Attendees will be notified of pending changes.")}
        </span>
        <button
          type="button"
          phx-click="cancel_pending_notification"
          phx-target={@myself}
          class="text-token-sm text-turquoise-800 hover:text-turquoise-900 underline"
        >
          {dgettext("dashboard_calendar_events", "Cancel")}
        </button>
      </div>

      <%!--
        Custom header: title gets full width, close button is absolute top-right.
        A text input cannot wrap, so a long editable title steps down a size on a
        phone and ends in an ellipsis while unfocused, with the full text in
        `title`; the read-only heading wraps instead. Both take the shared modal
        title's scale, since this header stands in for it.
      --%>
      <div class="relative mb-1">
        <.icon_button
          icon="hero-x-mark"
          variant={:danger}
          size={:sm}
          label={dgettext("dashboard_calendar_events", "Close modal")}
          class="absolute -top-2 -right-2"
          phx-click={JS.push("close_event_detail", target: @myself)}
        />
        <form
          :if={@editable}
          id="event-title-form"
          phx-change="update_event_title"
          phx-target={@myself}
          phx-submit="update_event_title"
          class="pr-8"
        >
          <input
            type="text"
            id="event-title-input"
            name="value"
            value={@selected_event.summary || ""}
            title={@selected_event.summary}
            placeholder={dgettext("dashboard_calendar_events", "(No title)")}
            phx-blur="update_event_title"
            phx-target={@myself}
            phx-debounce="500"
            class="w-full bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-xl sm:text-token-2xl text-ellipsis font-black text-tymeslot-900 tracking-tight px-0 py-0 placeholder:text-tymeslot-400 transition-colors cursor-text"
          />
        </form>
        <h3
          :if={!@editable}
          class="text-token-xl sm:text-token-2xl font-black text-tymeslot-900 tracking-tight pr-8 break-words"
        >
          {DashboardFormat.title(@selected_event.summary)}
        </h3>
      </div>

      <div class={"h-1 rounded-token-full w-10 mb-2 #{Helpers.color_for_event(assigns, @selected_event)}"}>
      </div>

      <div
        :if={Map.get(@selected_event, :created_by_tymeslot)}
        class="flex items-center gap-1 text-token-xs text-tymeslot-500 mb-2"
      >
        <img src="/images/brand/logo.svg" alt="" class="w-3.5 h-3.5" />
        <span>{dgettext("dashboard_calendar_events", "Created by Tymeslot")}</span>
      </div>

      <%!-- Time --%>
      <.detail_line variant={:compact} icon="hero-clock" class="mb-3">
        <% start_parts = Helpers.datetime_to_local_parts(@selected_event.start_at, @user_timezone) %>
        <% end_parts = Helpers.datetime_to_local_parts(@selected_event.end_at, @user_timezone) %>
        <div :if={@editable and not @time_locked} class="flex items-center justify-between mb-2">
          <span class="text-token-xs font-medium text-tymeslot-400">{dgettext(
            "dashboard_calendar_events",
            "All day"
          )}</span>
          <StatusSwitch.status_switch
            id="event-all-day"
            checked={@selected_event.all_day || false}
            on_change="toggle_event_all_day"
            target={@myself}
            size={:small}
          />
        </div>
        <form
          :if={@editable and not @time_locked and @selected_event.all_day}
          id="event-all-day-form"
          phx-change="update_event_all_day_range"
          phx-target={@myself}
          class="flex flex-wrap items-center gap-1 text-token-sm"
        >
          <input
            type="date"
            id="event-all-day-start"
            name="start-date"
            value={@selected_event.start_date && Date.to_iso8601(@selected_event.start_date)}
            class="bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-700 font-medium px-0 py-0 transition-colors cursor-text"
          />
          <span class="text-tymeslot-400">&ndash;</span>
          <%!-- end_date is stored exclusively; show the inclusive last day. --%>
          <input
            type="date"
            id="event-all-day-end"
            name="end-date"
            value={
              @selected_event.end_date && Date.to_iso8601(Date.add(@selected_event.end_date, -1))
            }
            class="bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-700 font-medium px-0 py-0 transition-colors cursor-text"
          />
        </form>
        <form
          :if={@editable and not @time_locked and not @selected_event.all_day}
          id="event-time-form"
          phx-change="update_event_time"
          phx-target={@myself}
          class="flex flex-wrap items-center gap-1 text-token-sm"
        >
          <input
            type="date"
            id="event-start-date"
            name="start-date"
            value={start_parts.date}
            class="bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-700 font-medium px-0 py-0 transition-colors cursor-text"
          />
          <input
            type="time"
            id="event-start-time"
            name="start-time"
            value={start_parts.time}
            class="bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-700 font-medium px-0 py-0 transition-colors cursor-text"
          />
          <span class="text-tymeslot-400">&ndash;</span>
          <input
            type="date"
            id="event-end-date"
            name="end-date"
            value={end_parts.date}
            class="bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-700 font-medium px-0 py-0 transition-colors cursor-text"
          />
          <input
            type="time"
            id="event-end-time"
            name="end-time"
            value={end_parts.time}
            class="bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-700 font-medium px-0 py-0 transition-colors cursor-text"
          />
          <span class="text-token-xs font-normal text-tymeslot-400 ml-1">{Helpers.tz_abbr(
            @user_timezone
          )}</span>
        </form>
        <div :if={!@editable or @time_locked}>
          <p class="text-token-sm font-medium text-tymeslot-700">
            {Helpers.format_display_time_range(@selected_event, @time_format, @user_timezone)}
            <span
              :if={!@selected_event.all_day}
              class="text-token-xs font-normal text-tymeslot-400 ml-1"
            >
              {Helpers.tz_abbr(@user_timezone)}
            </span>
          </p>
          <p class="text-token-xs text-tymeslot-400 mt-0.5">
            {DashboardFormat.long_date(Helpers.event_display_date(@selected_event, @user_timezone))}
          </p>
          <p
            :if={@time_locked}
            class="flex items-start gap-1 text-token-xs text-tymeslot-500 mt-1"
            id="event-time-locked-note"
          >
            <.icon name="hero-lock-closed-micro" class="w-3 h-3 mt-px shrink-0" />
            <span>{Shared.seat_lock_message()}</span>
          </p>
        </div>
      </.detail_line>

      <%!-- Location --%>
      <.detail_line :if={@editable} variant={:compact} icon="hero-map-pin" class="mb-3">
        <input
          type="text"
          id="event-location-input"
          name="value"
          value={@selected_event.location || ""}
          placeholder={dgettext("dashboard_calendar_events", "Add location")}
          phx-blur="update_event_location"
          phx-target={@myself}
          phx-debounce="500"
          class="w-full bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-600 px-0 py-0 placeholder:text-tymeslot-400 transition-colors cursor-text"
        />
      </.detail_line>
      <.detail_line
        :if={!@editable and @selected_event.location}
        variant={:compact}
        icon="hero-map-pin"
        class="mb-3"
      >
        <a
          :if={Helpers.url?(@selected_event.location)}
          href={@selected_event.location}
          target="_blank"
          rel="noopener noreferrer"
          class="text-token-sm text-turquoise-600 hover:text-turquoise-800 underline break-all"
        >
          {@selected_event.location}
        </a>
        <p :if={!Helpers.url?(@selected_event.location)} class="text-token-sm text-tymeslot-600">
          {@selected_event.location}
        </p>
      </.detail_line>

      <%!-- Description --%>
      <.detail_line :if={@editable} variant={:compact} icon="hero-bars-3-bottom-left" class="mb-3">
        <textarea
          id="event-description-input"
          name="value"
          placeholder={dgettext("dashboard_calendar_events", "Add description")}
          phx-blur="update_event_description"
          phx-target={@myself}
          phx-debounce="500"
          rows="5"
          class="w-full bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-600 px-0 py-0 placeholder:text-tymeslot-400 transition-colors cursor-text resize-none min-h-[6rem]"
          style="field-sizing: content"
        ><%= @selected_event.description || "" %></textarea>
      </.detail_line>
      <.detail_line
        :if={!@editable and @selected_event.description}
        variant={:compact}
        icon="hero-bars-3-bottom-left"
        class="mb-3"
      >
        <div class="text-token-sm text-tymeslot-600 max-h-52 overflow-y-auto whitespace-pre-line break-words leading-relaxed">
          {Helpers.linkify_text(@selected_event.description)}
        </div>
      </.detail_line>

      <%!-- Attendees --%>
      <AttendeeEditor.attendee_editor
        editable={@editable and not @time_locked}
        attendees={@attendees}
        pending_attendees={@pending_attendees}
        attendee_input={@attendee_input}
        myself={@myself}
      />

      <%!-- Video integration --%>
      <.detail_line
        :if={@editable and @video_integrations != []}
        variant={:compact}
        icon="hero-video-camera"
        label={dgettext("dashboard_calendar_events", "Video")}
        class="mb-3"
      >
        <VideoPicker.video_picker
          video_integrations={@video_integrations}
          selected_id={Map.get(@selected_event, :video_integration_id)}
          target={@myself}
          phx_event="update_edit_video"
        />
      </.detail_line>

      <%!-- Repeat --%>
      <div :if={@editable and not @time_locked} class="mb-3">
        <RecurrenceEditor.recurrence_editor
          recurrence_rule={Map.get(@selected_event, :recurrence_rule)}
          timezone={Shared.recurrence_timezone(@selected_event, @user_timezone)}
          myself={@myself}
          change_event="update_event_recurrence"
        />
      </div>
      <.detail_line
        :if={
          (!@editable or @time_locked) and
            recurrence_summary(@selected_event, @user_timezone) != nil
        }
        variant={:compact}
        icon="hero-arrow-path"
        class="mb-3"
      >
        <p class="text-token-sm text-tymeslot-600 leading-snug">
          {recurrence_summary(@selected_event, @user_timezone)}
        </p>
      </.detail_line>

      <%!-- Reminders --%>
      <RemindersEditor.reminders_editor
        :if={@editable}
        reminders={Map.get(@selected_event, :reminders) || []}
        myself={@myself}
        add_event="add_event_reminder"
        remove_event="remove_event_reminder"
      />
      <.detail_line
        :if={!@editable and (Map.get(@selected_event, :reminders) || []) != []}
        variant={:compact}
        icon="hero-bell"
        class="mb-3"
      >
        <p
          :for={reminder <- Map.get(@selected_event, :reminders) || []}
          class="text-token-sm text-tymeslot-600 leading-snug"
        >
          {RemindersEditor.reminder_label(reminder)}
        </p>
      </.detail_line>

      <%!-- Calendar picker --%>
      <.detail_line :if={@editable} variant={:compact} icon="hero-calendar" class="mb-3">
        <CalendarPicker.calendar_picker
          integrations={@integrations}
          integration_colors={@integration_colors}
          selected_integration_id={@selected_event.calendar_integration_id}
          selected_calendar_id={
            CalendarPicker.derive_event_calendar_id(
              @selected_event,
              Enum.find(@integrations, &(&1.id == @selected_event.calendar_integration_id))
            )
          }
          myself={@myself}
          event_name="update_event_calendar"
        />
      </.detail_line>

      <%!-- Colour --%>
      <.detail_line
        :if={@editable}
        variant={:compact}
        icon="hero-swatch"
        label={dgettext("dashboard_calendar_events", "Colour")}
        class="mb-3"
      >
        <ColourSwatches.colour_swatches
          selected={Map.get(@selected_event, :colour)}
          event="update_event_colour"
          target={@myself}
          group_label={dgettext("dashboard_calendar_events", "Colour")}
        />
      </.detail_line>

      <%!-- Footer actions --%>
      <div
        :if={@editable and not @time_locked}
        class="mt-4 pt-3 border-t border-tymeslot-100 flex items-center"
      >
        <.action_button
          variant={:danger_soft}
          size={:sm}
          icon="hero-trash"
          phx-click="request_delete_event"
          phx-target={@myself}
        >
          {dgettext("dashboard_calendar_events", "Delete event")}
        </.action_button>
      </div>
    </.modal>
    """
  end

  # Read-only human-readable summary of an event's recurrence rule, or nil when
  # the event does not repeat. The rule's UNTIL is an instant written in UTC, so
  # it is read back in the zone it was written against, the event's own.
  defp recurrence_summary(event, user_timezone) do
    case Map.get(event, :recurrence_rule) do
      rule when is_binary(rule) and rule != "" ->
        rule
        |> RRule.parse(timezone: Shared.recurrence_timezone(event, user_timezone))
        |> RecurrenceEditor.summary()

      _none ->
        nil
    end
  end

  # Cached attendees come back from JSONB string-keyed, while one the organiser
  # has just added is still atom-keyed in memory, so the editor reads them all
  # in the one canonical shape.
  defp attendees(event) do
    event
    |> Map.get(:attendees)
    |> List.wrap()
    |> Enum.map(&Attendee.normalise/1)
  end
end
