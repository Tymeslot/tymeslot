defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.EventDetailModal do
  @moduledoc "Event detail/edit modal for viewing and editing calendar events."

  use TymeslotWeb, :html

  alias Phoenix.LiveView.JS
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.CalendarPicker
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrenceEditor
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RemindersEditor

  attr :selected_event, :map, required: true
  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :user_timezone, :string, required: true
  attr :time_format, :string, default: "12h"
  attr :myself, :any, required: true
  attr :editable, :boolean, default: false
  attr :attendee_input, :string, default: ""
  attr :pending_attendees, :list, default: []
  attr :video_integrations, :list, default: []
  attr :pending_notification, :boolean, default: false

  @spec event_detail_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def event_detail_modal(assigns) do
    assigns =
      assign(
        assigns,
        :read_only_attendees,
        List.wrap(Map.get(assigns.selected_event, :attendees))
      )

    ~H"""
    <.modal
      id="event-detail-modal"
      show={true}
      on_cancel={JS.push("close_event_detail", target: @myself)}
      size={:medium}
      aria_label={@selected_event.summary || "Event details"}
    >
      <%!-- Pending-notification banner --%>
      <div
        :if={@pending_notification}
        class="rounded-lg bg-turquoise-50 border border-turquoise-200 p-2 mb-3 flex items-center justify-between"
      >
        <span class="text-token-sm text-turquoise-900">
          Attendees will be notified of pending changes.
        </span>
        <button
          type="button"
          phx-click="cancel_pending_notification"
          phx-target={@myself}
          class="text-token-sm text-turquoise-800 hover:text-turquoise-900 underline"
        >
          Cancel
        </button>
      </div>

      <%!-- Custom header: title gets full width, close button is absolute top-right --%>
      <div class="relative mb-1">
        <button
          type="button"
          class="absolute -top-2 -right-2 w-8 h-8 rounded-lg bg-tymeslot-50 text-tymeslot-400 hover:bg-red-50 hover:text-red-500 transition-all flex items-center justify-center"
          aria-label="Close modal"
          phx-click={JS.push("close_event_detail", target: @myself)}
        >
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M6 18L18 6M6 6l12 12" />
          </svg>
        </button>
        <form id="event-title-form" :if={@editable} phx-change="update_event_title" phx-target={@myself} phx-submit="update_event_title" class="pr-8">
          <input
            type="text"
            id="event-title-input"
            name="value"
            value={@selected_event.summary || ""}
            placeholder="(No title)"
            phx-blur="update_event_title"
            phx-target={@myself}
            phx-debounce="500"
            class="w-full bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-2xl font-black text-tymeslot-900 tracking-tight px-0 py-0 placeholder:text-tymeslot-400 transition-colors cursor-text"
          />
        </form>
        <h3 :if={!@editable} class="text-token-2xl font-black text-tymeslot-900 tracking-tight pr-8">
          <%= @selected_event.summary || "(No title)" %>
        </h3>
      </div>

      <div class={"h-1 rounded-full w-10 mb-2 #{Helpers.color_for_event(assigns, @selected_event)}"}></div>

      <div :if={Map.get(@selected_event, :created_by_tymeslot)} class="flex items-center gap-1 text-token-xs text-tymeslot-500 mb-2">
        <img src="/images/brand/logo.svg" alt="" class="w-3.5 h-3.5" />
        <span>Created by Tymeslot</span>
      </div>

      <%!-- Time --%>
      <div class="flex items-start gap-3 mb-3">
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" title="Time">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
        </svg>
        <div class="flex-1">
          <% start_parts = Helpers.datetime_to_local_parts(@selected_event.start_at, @user_timezone) %>
          <% end_parts = Helpers.datetime_to_local_parts(@selected_event.end_at, @user_timezone) %>
          <div :if={@editable} class="flex items-center justify-between mb-2">
            <span class="text-token-xs font-medium text-tymeslot-400">All day</span>
            <StatusSwitch.status_switch
              id="event-all-day"
              checked={@selected_event.all_day || false}
              on_change="toggle_event_all_day"
              target={@myself}
              size={:small}
            />
          </div>
          <form id="event-all-day-form" :if={@editable and @selected_event.all_day} phx-change="update_event_all_day_range" phx-target={@myself} class="flex flex-wrap items-center gap-1 text-token-sm">
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
              value={@selected_event.end_date && Date.to_iso8601(Date.add(@selected_event.end_date, -1))}
              class="bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-700 font-medium px-0 py-0 transition-colors cursor-text"
            />
          </form>
          <form id="event-time-form" :if={@editable and not @selected_event.all_day} phx-change="update_event_time" phx-target={@myself} class="flex flex-wrap items-center gap-1 text-token-sm">
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
            <span class="text-token-xs font-normal text-tymeslot-400 ml-1"><%= Helpers.tz_abbr(@user_timezone) %></span>
          </form>
          <div :if={!@editable}>
            <p class="text-token-sm font-medium text-tymeslot-700">
              <span :if={@selected_event.all_day}>All day</span>
              <span :if={!@selected_event.all_day}>
                <%= Helpers.format_time_range_in_tz(@selected_event, @user_timezone, @time_format) %>
                <span class="text-token-xs font-normal text-tymeslot-400 ml-1"><%= Helpers.tz_abbr(@user_timezone) %></span>
              </span>
            </p>
            <p class="text-token-xs text-tymeslot-400 mt-0.5">
              <%= Calendar.strftime(Helpers.event_display_date(@selected_event, @user_timezone), "%A, %B %-d") %>
            </p>
          </div>
        </div>
      </div>

      <%!-- Location --%>
      <div :if={@editable} class="flex items-start gap-3 mb-3">
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" title="Location">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z" />
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z" />
        </svg>
        <input
          type="text"
          id="event-location-input"
          name="value"
          value={@selected_event.location || ""}
          placeholder="Add location"
          phx-blur="update_event_location"
          phx-target={@myself}
          phx-debounce="500"
          class="flex-1 bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-600 px-0 py-0 placeholder:text-tymeslot-400 transition-colors cursor-text"
        />
      </div>
      <div :if={!@editable and @selected_event.location} class="flex items-start gap-3 mb-3">
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z" />
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z" />
        </svg>
        <a
          :if={Helpers.url?(@selected_event.location)}
          href={@selected_event.location}
          target="_blank"
          rel="noopener noreferrer"
          class="text-token-sm text-turquoise-600 hover:text-turquoise-800 underline break-all"
        >
          <%= @selected_event.location %>
        </a>
        <p :if={!Helpers.url?(@selected_event.location)} class="text-token-sm text-tymeslot-600"><%= @selected_event.location %></p>
      </div>

      <%!-- Description --%>
      <div :if={@editable} class="flex items-start gap-3 mb-3">
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" title="Description">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h7" />
        </svg>
        <textarea
          id="event-description-input"
          name="value"
          placeholder="Add description"
          phx-blur="update_event_description"
          phx-target={@myself}
          phx-debounce="500"
          rows="5"
          class="flex-1 bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-600 px-0 py-0 placeholder:text-tymeslot-400 transition-colors cursor-text resize-none min-h-[6rem]"
          style="field-sizing: content"
        ><%= @selected_event.description || "" %></textarea>
      </div>
      <div :if={!@editable and @selected_event.description} class="flex items-start gap-3 mb-3">
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h7" />
        </svg>
        <div class="text-token-sm text-tymeslot-600 max-h-52 overflow-y-auto whitespace-pre-line break-words flex-1 leading-relaxed">
          <%= Helpers.linkify_text(@selected_event.description) %>
        </div>
      </div>

      <%!-- Attendees --%>
      <div :if={@editable or not Enum.empty?(@selected_event.attendees || [])} class="flex items-start gap-3 mb-3">
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" title="Attendees">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0z" />
        </svg>
        <div class="flex-1">
          <%!-- Editable attendee tags --%>
          <div :if={@editable}>
            <div
              :if={(@selected_event.attendees || []) != [] or @pending_attendees != []}
              class="flex flex-wrap gap-1.5 mb-2"
            >
              <%!-- Existing (invited) attendees — turquoise --%>
              <span
                :for={attendee <- @selected_event.attendees || []}
                class="inline-flex items-center gap-1 pl-2.5 pr-1 py-0.5 rounded-full bg-turquoise-50 border border-turquoise-200 text-token-xs text-turquoise-800"
              >
                {attendee["name"] || attendee["email"] || attendee[:email]}
                <button
                  type="button"
                  phx-click="request_remove_attendee"
                  phx-value-email={attendee["email"] || attendee[:email]}
                  phx-target={@myself}
                  class="w-4 h-4 rounded-full hover:bg-red-100 flex items-center justify-center transition-colors"
                  aria-label={"Remove #{attendee["email"] || attendee[:email]}"}
                >
                  <svg class="w-2.5 h-2.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </button>
              </span>
              <%!-- Pending (unsent) attendees — amber dashed --%>
              <span
                :for={email <- @pending_attendees}
                class="inline-flex items-center gap-1 pl-2.5 pr-1 py-0.5 rounded-full bg-amber-50 border border-dashed border-amber-300 text-token-xs text-amber-800"
              >
                {email}
                <button
                  type="button"
                  phx-click="remove_pending_attendee"
                  phx-value-email={email}
                  phx-target={@myself}
                  class="w-4 h-4 rounded-full hover:bg-amber-200 flex items-center justify-center transition-colors"
                  aria-label={"Remove #{email}"}
                >
                  <svg class="w-2.5 h-2.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </button>
              </span>
            </div>
            <form id="event-add-attendee-form" phx-submit="add_event_attendee" phx-target={@myself} class="flex gap-2">
              <input
                type="email"
                id="edit-attendee-email"
                name="email"
                value={@attendee_input}
                phx-change="update_attendee_input"
                phx-target={@myself}
                placeholder="attendee@example.com"
                class="flex-1 bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-600 px-0 py-0 placeholder:text-tymeslot-400 transition-colors cursor-text"
              />
              <button
                type="submit"
                class="px-2 py-0.5 rounded-md border border-tymeslot-200 text-token-xs text-tymeslot-500 hover:bg-tymeslot-50 transition-colors"
              >
                Add
              </button>
            </form>
            <p :if={@pending_attendees == []} class="text-token-xs text-tymeslot-400 mt-1">
              Each person will receive an invitation from your calendar provider.
            </p>
          </div>
          <%!-- Read-only attendee display --%>
          <div :if={!@editable}>
            <div :for={attendee <- Enum.take(@read_only_attendees, 5)} class="text-token-sm text-tymeslot-700 leading-snug">
              <%= attendee["name"] || attendee["email"] %>
              <span :if={attendee["name"] && attendee["email"] && attendee["name"] != attendee["email"]} class="text-token-xs text-tymeslot-400 ml-1"><%= attendee["email"] %></span>
            </div>
            <p :if={length(@read_only_attendees) > 5} class="text-token-xs text-tymeslot-400 mt-1">+<%= length(@read_only_attendees) - 5 %> more</p>
          </div>
        </div>
      </div>

      <%!-- Video integration --%>
      <div :if={@editable and @video_integrations != []} class="flex items-start gap-3 mb-3">
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" title="Video">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z" />
        </svg>
        <div class="flex-1">
          <p class="text-token-xs font-medium text-tymeslot-400 mb-1.5">Video</p>
          <.video_integration_selector
            video_integrations={@video_integrations}
            selected_id={Map.get(@selected_event, :video_integration_id)}
            target={@myself}
            phx_event="update_edit_video"
          />
        </div>
      </div>

      <%!-- Repeat --%>
      <div :if={@editable} class="mb-3">
        <RecurrenceEditor.recurrence_editor
          recurrence_rule={Map.get(@selected_event, :recurrence_rule)}
          myself={@myself}
          change_event="update_event_recurrence"
        />
      </div>
      <div
        :if={!@editable and recurrence_summary(@selected_event) != nil}
        class="flex items-start gap-3 mb-3"
      >
        <.icon name="hero-arrow-path" class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" />
        <div class="flex-1">
          <p class="text-token-sm text-tymeslot-600 leading-snug">
            {recurrence_summary(@selected_event)}
          </p>
        </div>
      </div>

      <%!-- Reminders --%>
      <RemindersEditor.reminders_editor
        :if={@editable}
        reminders={Map.get(@selected_event, :reminders) || []}
        myself={@myself}
        add_event="add_event_reminder"
        remove_event="remove_event_reminder"
      />
      <div :if={!@editable and (Map.get(@selected_event, :reminders) || []) != []} class="flex items-start gap-3 mb-3">
        <.icon name="hero-bell" class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" />
        <div class="flex-1">
          <p :for={reminder <- Map.get(@selected_event, :reminders) || []} class="text-token-sm text-tymeslot-600 leading-snug">
            <%= RemindersEditor.reminder_label(reminder) %>
          </p>
        </div>
      </div>

      <%!-- Calendar picker --%>
      <div :if={@editable} class="flex items-start gap-3 mb-3">
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" title="Calendar">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z" />
        </svg>
        <div class="flex-1">
          <CalendarPicker.calendar_picker
            integrations={@integrations}
            integration_colors={@integration_colors}
            selected_integration_id={@selected_event.calendar_integration_id}
            selected_calendar_id={CalendarPicker.derive_event_calendar_id(@selected_event, Enum.find(@integrations, &(&1.id == @selected_event.calendar_integration_id)))}
            myself={@myself}
            event_name="update_event_calendar"
          />
        </div>
      </div>

      <%!-- Colour --%>
      <div :if={@editable} class="flex items-start gap-3 mb-3">
        <.icon name="hero-swatch" class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" />
        <div class="flex-1">
          <p class="text-token-xs font-medium text-tymeslot-400 mb-1.5">Colour</p>
          <.colour_swatches selected={Map.get(@selected_event, :colour)} target={@myself} />
        </div>
      </div>

      <%!-- Footer actions --%>
      <div :if={@editable} class="mt-4 pt-3 border-t border-tymeslot-100 flex items-center">
        <button
          type="button"
          phx-click="request_delete_event"
          phx-target={@myself}
          class="text-token-sm text-red-500 hover:text-red-700 transition-colors"
        >
          Delete event
        </button>
      </div>
    </.modal>
    """
  end

  # Read-only human-readable summary of an event's recurrence rule, or nil when
  # the event does not repeat.
  defp recurrence_summary(event) do
    case Map.get(event, :recurrence_rule) do
      rule when is_binary(rule) and rule != "" ->
        rule |> RRule.parse() |> RecurrenceEditor.summary()

      _none ->
        nil
    end
  end

  attr :selected, :any, default: nil
  attr :target, :any, required: true

  # Palette swatch picker. A "Default" pill clears the override (falling back to
  # the per-calendar colour); each swatch pushes the palette key. The active
  # option is ringed.
  defp colour_swatches(assigns) do
    assigns = assign(assigns, :palette, EventColour.palette())

    ~H"""
    <div class="flex flex-wrap items-center gap-1.5">
      <button
        type="button"
        phx-click="update_event_colour"
        phx-value-colour="default"
        phx-target={@target}
        class={"inline-flex items-center gap-1 px-2 py-1 rounded-lg border text-token-xs transition-all #{if is_nil(@selected), do: "border-turquoise-400 bg-turquoise-50 text-turquoise-800 shadow-sm font-semibold", else: "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"}"}
      >
        Default
      </button>
      <button
        :for={{key, label, swatch_class} <- @palette}
        type="button"
        phx-click="update_event_colour"
        phx-value-colour={key}
        phx-target={@target}
        title={label}
        aria-label={label}
        aria-pressed={to_string(@selected == key)}
        class={"w-6 h-6 rounded-full #{swatch_class} ring-2 ring-offset-1 transition-all #{if @selected == key, do: "ring-turquoise-500", else: "ring-transparent hover:ring-tymeslot-300"}"}
      >
      </button>
    </div>
    """
  end

  attr :video_integrations, :list, required: true
  attr :selected_id, :any, default: nil
  attr :target, :any, required: true
  attr :phx_event, :string, required: true

  defp video_integration_selector(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1.5">
      <button
        type="button"
        phx-click={@phx_event}
        phx-value-video_integration_id=""
        phx-target={@target}
        class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border text-token-xs transition-all #{if is_nil(@selected_id), do: "border-turquoise-400 bg-turquoise-50 text-turquoise-800 shadow-sm font-semibold", else: "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"}"}
      >
        None
      </button>
      <button
        :for={vi <- @video_integrations}
        type="button"
        phx-click={@phx_event}
        phx-value-video_integration_id={vi.id}
        phx-target={@target}
        class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border text-token-xs transition-all #{if to_string(vi.id) == to_string(@selected_id), do: "border-turquoise-400 bg-turquoise-50 text-turquoise-800 shadow-sm font-semibold", else: "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"}"}
      >
        <ProviderIcon.provider_icon provider={vi.provider} type="video" size="mini" />
        <span class="truncate max-w-[10rem]"><%= vi.name %></span>
      </button>
    </div>
    """
  end
end
