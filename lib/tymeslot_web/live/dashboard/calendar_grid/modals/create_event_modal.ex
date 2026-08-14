defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.CreateEventModal do
  @moduledoc "Create event modal for the calendar grid."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.CalendarPicker
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrenceEditor
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RemindersEditor

  attr :creating_event, :map, required: true
  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :saving, :boolean, default: false
  attr :user_timezone, :string, required: true
  attr :myself, :any, required: true
  attr :video_integrations, :list, default: []

  @spec create_event_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def create_event_modal(assigns) do
    assigns = assign(assigns, :meeting_mode, assigns.creating_event[:mode] == :meeting)

    ~H"""
    <.modal
      id="create-event-modal"
      show={true}
      on_cancel={JS.push("close_create_form", target: @myself)}
      size={:medium}
    >
      <:header>
        {if @meeting_mode,
          do: dgettext("dashboard_calendar_events", "New Meeting"),
          else: dgettext("dashboard_calendar_events", "New Event")}
      </:header>

      <%!-- Mode toggle: a bare provider event vs an ad-hoc Tymeslot meeting.
            Hidden when no calendar is connected — the form is then fixed to
            meeting mode, the only kind that can exist without one. --%>
      <div :if={@integrations != []} class="mb-4">
        <div
          class="inline-flex rounded-token-lg border border-tymeslot-200 p-0.5 gap-0.5"
          role="tablist"
          aria-label={dgettext("dashboard_calendar_events", "What to create")}
        >
          <button
            type="button"
            role="tab"
            aria-selected={to_string(!@meeting_mode)}
            phx-click="set_create_mode"
            phx-value-mode="event"
            phx-target={@myself}
            class={"px-3 py-1.5 rounded-token-md text-token-sm font-semibold transition-colors #{if !@meeting_mode, do: "bg-turquoise-600 text-white shadow-sm", else: "text-tymeslot-600 hover:bg-tymeslot-50"}"}
          >
            {dgettext("dashboard_calendar_events", "Event")}
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={to_string(@meeting_mode)}
            phx-click="set_create_mode"
            phx-value-mode="meeting"
            phx-target={@myself}
            data-testid="create-mode-meeting"
            class={"px-3 py-1.5 rounded-token-md text-token-sm font-semibold transition-colors #{if @meeting_mode, do: "bg-turquoise-600 text-white shadow-sm", else: "text-tymeslot-600 hover:bg-tymeslot-50"}"}
          >
            {dgettext("dashboard_calendar_events", "Meeting with a guest")}
          </button>
        </div>
        <p :if={@meeting_mode} class="mt-1.5 text-token-xs text-tymeslot-400">
          {dgettext(
            "dashboard_calendar_events",
            "Books the slot, emails the guest an invitation, and adds it to your calendar."
          )}
        </p>
      </div>

      <div class="mb-3">
        <.input
          type="text"
          name="title"
          value={@creating_event.title}
          label={dgettext("dashboard_calendar_events", "Title")}
          placeholder={dgettext("dashboard_calendar_events", "Add title")}
          id="create-event-title"
          phx-mounted={JS.focus()}
          phx-blur="update_create_title"
          phx-target={@myself}
        />
      </div>

      <%!-- Guest details (meeting mode only) --%>
      <div :if={@meeting_mode} class="mb-3 grid gap-3 sm:grid-cols-2">
        <.input
          type="text"
          name="guest_name"
          value={@creating_event[:guest_name] || ""}
          label={dgettext("dashboard_calendar_events", "Guest name")}
          placeholder={dgettext("dashboard_calendar_events", "Ada Lovelace")}
          id="create-meeting-guest-name"
          phx-blur="update_create_guest_name"
          phx-target={@myself}
        />
        <.input
          type="email"
          name="guest_email"
          value={@creating_event[:guest_email] || ""}
          label={dgettext("dashboard_calendar_events", "Guest email")}
          placeholder="guest@example.com"
          id="create-meeting-guest-email"
          phx-blur="update_create_guest_email"
          phx-target={@myself}
        />
      </div>

      <div :if={!@meeting_mode} class="mb-3 flex items-center justify-between">
        <p class="text-token-sm font-medium text-tymeslot-700">
          {dgettext("dashboard_calendar_events", "All day")}
        </p>
        <StatusSwitch.status_switch
          id="create-event-all-day"
          checked={@creating_event[:all_day] || false}
          on_change="toggle_create_all_day"
          target={@myself}
          size={:small}
        />
      </div>

      <div class="mb-3">
        <form
          id="create-event-time-form"
          phx-change="update_create_time"
          phx-target={@myself}
          class="flex flex-wrap items-center gap-1 text-token-sm text-tymeslot-600"
        >
          <input
            type="date"
            id="create-event-start-date"
            name="start-date"
            value={@creating_event.date}
            class="bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-700 font-medium px-0 py-0 transition-colors cursor-text"
          />
          <input
            :if={!@creating_event[:all_day]}
            type="time"
            id="create-event-start-time"
            name="start-time"
            value={
              EditWorkflow.format_time_value(@creating_event.start_hour, @creating_event.start_minute)
            }
            class="bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-700 font-medium px-0 py-0 transition-colors cursor-text"
          />
          <span class="text-tymeslot-400">&ndash;</span>
          <input
            type="date"
            id="create-event-end-date"
            name="end-date"
            value={@creating_event.end_date}
            class="bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-700 font-medium px-0 py-0 transition-colors cursor-text"
          />
          <input
            :if={!@creating_event[:all_day]}
            type="time"
            id="create-event-end-time"
            name="end-time"
            value={
              EditWorkflow.format_time_value(@creating_event.end_hour, @creating_event.end_minute)
            }
            class="bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-700 font-medium px-0 py-0 transition-colors cursor-text"
          />
          <span
            :if={!@creating_event[:all_day]}
            class="text-token-xs font-normal text-tymeslot-400 ml-1"
          >{Helpers.tz_abbr(@user_timezone)}</span>
        </form>
      </div>

      <CalendarPicker.calendar_picker
        :if={@integrations != []}
        integrations={@integrations}
        integration_colors={@integration_colors}
        selected_integration_id={@creating_event.integration_id}
        selected_calendar_id={@creating_event[:calendar_id]}
        myself={@myself}
        event_name="update_create_integration"
      />

      <%!-- Video (meeting mode): which provider backs the meeting link --%>
      <div
        :if={@meeting_mode and @video_integrations != []}
        class="border-t border-tymeslot-200 pt-3 mt-3"
      >
        <p class="text-token-xs font-medium text-tymeslot-400 mb-1.5">
          {dgettext("dashboard_calendar_events", "Video")}
        </p>
        <div class="flex flex-wrap gap-1.5">
          <button
            type="button"
            phx-click="update_create_video"
            phx-value-video_integration_id=""
            phx-target={@myself}
            class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border text-token-xs transition-all #{if is_nil(@creating_event[:video_integration_id]), do: "border-turquoise-400 bg-turquoise-50 text-turquoise-800 shadow-sm font-semibold", else: "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"}"}
          >
            {dgettext("dashboard_calendar_events", "None")}
          </button>
          <button
            :for={vi <- @video_integrations}
            type="button"
            phx-click="update_create_video"
            phx-value-video_integration_id={vi.id}
            phx-target={@myself}
            class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border text-token-xs transition-all #{if to_string(vi.id) == to_string(@creating_event[:video_integration_id]), do: "border-turquoise-400 bg-turquoise-50 text-turquoise-800 shadow-sm font-semibold", else: "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"}"}
          >
            <ProviderIcon.provider_icon provider={vi.provider} type="video" size="mini" />
            <span class="truncate max-w-[10rem]">{vi.name}</span>
          </button>
        </div>
      </div>

      <%!-- Repeat --%>
      <div :if={!@meeting_mode} class="border-t border-tymeslot-200 pt-3 mt-3">
        <RecurrenceEditor.recurrence_editor
          recurrence_rule={@creating_event[:recurrence_rule]}
          myself={@myself}
          change_event="update_create_recurrence"
        />
      </div>

      <%!-- Reminders --%>
      <div :if={!@meeting_mode} class="border-t border-tymeslot-200 pt-3 mt-3">
        <RemindersEditor.reminders_editor
          reminders={@creating_event[:reminders] || []}
          myself={@myself}
          add_event="add_create_reminder"
          remove_event="remove_create_reminder"
        />
      </div>

      <%!-- Attendee section --%>
      <div :if={!@meeting_mode} class="space-y-3 border-t border-tymeslot-200 pt-3 mt-3">
        <p class="text-token-xs font-medium text-tymeslot-400">
          {dgettext("dashboard_calendar_events", "Invite attendees (optional)")}
        </p>
        <div>
          <div
            :if={@creating_event[:attendees] != []}
            class="flex flex-wrap gap-1.5 mb-2"
          >
            <span
              :for={email <- @creating_event[:attendees] || []}
              class="inline-flex items-center gap-1 pl-2.5 pr-1 py-0.5 rounded-full bg-amber-50 border border-dashed border-amber-300 text-token-xs text-amber-800"
            >
              {email}
              <button
                type="button"
                phx-click="remove_create_attendee"
                phx-value-email={email}
                phx-target={@myself}
                class="w-4 h-4 rounded-full hover:bg-amber-200 flex items-center justify-center transition-colors"
                aria-label={dgettext("dashboard_calendar_events", "Remove %{email}", email: email)}
              >
                <svg class="w-2.5 h-2.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="3"
                    d="M6 18L18 6M6 6l12 12"
                  />
                </svg>
              </button>
            </span>
          </div>
          <form
            id="create-add-attendee-form"
            phx-submit="add_create_attendee"
            phx-target={@myself}
            class="flex gap-2"
          >
            <input
              type="email"
              id="create-attendee-email"
              name="email"
              value={@creating_event[:attendee_input] || ""}
              phx-change="update_create_attendee_input"
              phx-target={@myself}
              placeholder="attendee@example.com"
              class="flex-1 rounded-md border-tymeslot-300 text-token-sm focus:border-turquoise-500 focus:ring-turquoise-500"
            />
            <button
              type="submit"
              class="px-3 py-1.5 rounded-md border border-tymeslot-300 text-token-xs text-tymeslot-600 hover:bg-tymeslot-50 transition-colors"
            >
              {dgettext("dashboard_calendar_events", "Add")}
            </button>
          </form>
          <p class="text-token-xs text-tymeslot-400 mt-1">
            {dgettext(
              "dashboard_calendar_events",
              "Invitations will be sent when you create the event."
            )}
          </p>
        </div>
        <div :if={(@creating_event[:attendees] || []) != [] and @video_integrations != []}>
          <p class="text-token-xs font-medium text-tymeslot-400 mb-1.5">
            {dgettext("dashboard_calendar_events", "Video")}
          </p>
          <div class="flex flex-wrap gap-1.5">
            <button
              type="button"
              phx-click="update_create_video"
              phx-value-video_integration_id=""
              phx-target={@myself}
              class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border text-token-xs transition-all #{if is_nil(@creating_event[:video_integration_id]), do: "border-turquoise-400 bg-turquoise-50 text-turquoise-800 shadow-sm font-semibold", else: "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"}"}
            >
              {dgettext("dashboard_calendar_events", "None")}
            </button>
            <button
              :for={vi <- @video_integrations}
              type="button"
              phx-click="update_create_video"
              phx-value-video_integration_id={vi.id}
              phx-target={@myself}
              class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border text-token-xs transition-all #{if to_string(vi.id) == to_string(@creating_event[:video_integration_id]), do: "border-turquoise-400 bg-turquoise-50 text-turquoise-800 shadow-sm font-semibold", else: "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"}"}
            >
              <ProviderIcon.provider_icon provider={vi.provider} type="video" size="mini" />
              <span class="truncate max-w-[10rem]">{vi.name}</span>
            </button>
          </div>
        </div>
      </div>

      <:footer>
        <div class="flex gap-2">
          <.loading_button
            variant={:primary}
            loading={@saving}
            loading_text={dgettext("dashboard_calendar_events", "Creating...")}
            phx-click="save_event"
            phx-target={@myself}
          >
            {dgettext("dashboard_calendar_events", "Create")}
          </.loading_button>
          <.action_button
            variant={:secondary}
            disabled={@saving}
            phx-click={JS.push("close_create_form", target: @myself)}
          >
            {dgettext("dashboard_calendar_events", "Cancel")}
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
