defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals do
  @moduledoc "Modal function components for the calendar grid."

  use TymeslotWeb, :html

  alias Phoenix.LiveView.JS
  alias Tymeslot.Integrations.Calendar, as: CalendarIntegration
  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Components.UI.Toggle
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  attr :creating_event, :map, required: true
  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :saving, :boolean, default: false
  attr :user_timezone, :string, required: true
  attr :myself, :any, required: true

  @spec create_event_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def create_event_modal(assigns) do
    ~H"""
    <.modal
      id="create-event-modal"
      show={true}
      on_cancel={JS.push("close_create_form", target: @myself)}
      size={:medium}
    >
      <:header>New Event</:header>

      <div class="mb-3">
        <.input
          type="text"
          name="title"
          value={@creating_event.title}
          label="Title"
          placeholder="Add title"
          id="create-event-title"
          phx-mounted={JS.focus()}
          phx-blur="update_create_title"
          phx-target={@myself}
        />
      </div>

      <div class="mb-3">
        <form phx-change="update_create_time" phx-target={@myself} class="flex flex-wrap items-center gap-1 text-token-sm text-tymeslot-600">
          <input
            type="date"
            id="create-event-date"
            name="date"
            value={@creating_event.date}
            class="bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-700 font-medium px-0 py-0 transition-colors cursor-text"
          />
          <input
            type="time"
            id="create-event-start-time"
            name="start-time"
            value={EditWorkflow.format_time_value(@creating_event.start_hour, @creating_event.start_minute)}
            class="bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-700 font-medium px-0 py-0 transition-colors cursor-text"
          />
          <span class="text-tymeslot-400">&ndash;</span>
          <input
            type="time"
            id="create-event-end-time"
            name="end-time"
            value={EditWorkflow.format_time_value(@creating_event.end_hour, @creating_event.end_minute)}
            class="bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-700 font-medium px-0 py-0 transition-colors cursor-text"
          />
          <span class="text-token-xs font-normal text-tymeslot-400 ml-1"><%= Helpers.tz_abbr(@user_timezone) %></span>
        </form>
      </div>

      <.calendar_picker
        integrations={@integrations}
        integration_colors={@integration_colors}
        selected_integration_id={@creating_event.integration_id}
        selected_calendar_id={@creating_event[:calendar_id]}
        myself={@myself}
        event_name="update_create_integration"
      />

      <:footer>
        <div class="flex gap-2">
          <.loading_button
            variant={:primary}
            loading={@saving}
            loading_text="Creating..."
            phx-click="save_event"
            phx-target={@myself}
          >
            Create
          </.loading_button>
          <.action_button
            variant={:secondary}
            disabled={@saving}
            phx-click={JS.push("close_create_form", target: @myself)}
          >
            Cancel
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end

  attr :recurrence_prompt, :map, required: true
  attr :myself, :any, required: true

  @spec recurrence_prompt_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def recurrence_prompt_modal(assigns) do
    ~H"""
    <.modal
      id="recurrence-prompt-modal"
      show={true}
      on_cancel={JS.push("cancel_recurrence_prompt", target: @myself)}
      size={:small}
    >
      <:header>Edit recurring event</:header>

      <p class="text-token-sm text-tymeslot-500 mb-4">Which events do you want to update?</p>

      <div class="flex flex-col gap-2 mb-4">
        <button
          phx-click="confirm_recurrence_scope"
          phx-value-scope="this_only"
          phx-target={@myself}
          class="w-full text-left px-4 py-2.5 rounded-lg border border-tymeslot-200 hover:bg-tymeslot-50 text-token-sm text-tymeslot-700"
        >
          This event only
        </button>
        <button
          phx-click="confirm_recurrence_scope"
          phx-value-scope="this_and_following"
          phx-target={@myself}
          class="w-full text-left px-4 py-2.5 rounded-lg border border-tymeslot-200 hover:bg-tymeslot-50 text-token-sm text-tymeslot-700"
        >
          This and following events
        </button>
        <button
          phx-click="confirm_recurrence_scope"
          phx-value-scope="all"
          phx-target={@myself}
          class="w-full text-left px-4 py-2.5 rounded-lg border border-tymeslot-200 hover:bg-tymeslot-50 text-token-sm text-tymeslot-700"
        >
          All events in series
        </button>
      </div>

      <:footer>
        <.action_button
          variant={:secondary}
          phx-click={JS.push("cancel_recurrence_prompt", target: @myself)}
        >
          Cancel
        </.action_button>
      </:footer>
    </.modal>
    """
  end

  attr :preferences, :any, required: true
  attr :myself, :any, required: true

  @spec settings_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_modal(assigns) do
    ~H"""
    <.modal
      id="calendar-settings-modal"
      show={true}
      on_cancel={JS.push("close_settings", target: @myself)}
      size={:small}
    >
      <:header>Calendar Settings</:header>

      <div class="space-y-5">
        <%!-- First day of week --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">First day of week</p>
            <p class="text-token-xs text-tymeslot-400">Start weeks on Monday or Sunday</p>
          </div>
          <Toggle.toggle
            id="week-start-toggle"
            active_option={safe_to_atom(@preferences.week_start_day, :monday)}
            phx_click="update_week_start"
            phx_target={@myself}
            options={[%{value: :monday, label: "Mon"}, %{value: :sunday, label: "Sun"}]}
            size={:small}
          />
        </div>

        <%!-- Time format --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">Time format</p>
            <p class="text-token-xs text-tymeslot-400">12-hour or 24-hour clock</p>
          </div>
          <Toggle.toggle
            id="time-format-toggle"
            active_option={safe_to_atom(@preferences.time_format, :"12h")}
            phx_click="update_time_format"
            phx_target={@myself}
            options={[%{value: :"12h", label: "12h"}, %{value: :"24h", label: "24h"}]}
            size={:small}
          />
        </div>

        <%!-- Default view --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">Default view</p>
            <p class="text-token-xs text-tymeslot-400">Also switches the current view</p>
          </div>
          <Toggle.toggle
            id="default-view-toggle"
            active_option={safe_to_atom(@preferences.default_view, :week)}
            phx_click="update_default_view"
            phx_target={@myself}
            options={[
              %{value: :day, label: "Day"},
              %{value: :week, label: "Week"},
              %{value: :month, label: "Month"}
            ]}
            size={:small}
          />
        </div>

        <%!-- Show week numbers --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">Week numbers</p>
            <p class="text-token-xs text-tymeslot-400">Show ISO week numbers in month view</p>
          </div>
          <StatusSwitch.status_switch
            id="week-numbers-switch"
            checked={@preferences.show_week_numbers}
            on_change="toggle_week_numbers"
            target={@myself}
            size={:small}
          />
        </div>

        <%!-- Show weekends --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">Show weekends</p>
            <p class="text-token-xs text-tymeslot-400">Display Saturday and Sunday in week view</p>
          </div>
          <StatusSwitch.status_switch
            id="weekends-switch"
            checked={@preferences.show_weekends}
            on_change="toggle_weekends"
            target={@myself}
            size={:small}
          />
        </div>
      </div>
    </.modal>
    """
  end

  attr :selected_event, :map, required: true
  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :user_timezone, :string, required: true
  attr :time_format, :string, default: "12h"
  attr :myself, :any, required: true
  attr :editable, :boolean, default: false

  @spec event_detail_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def event_detail_modal(assigns) do
    ~H"""
    <.modal
      id="event-detail-modal"
      show={true}
      on_cancel={JS.push("close_event_detail", target: @myself)}
      size={:medium}
    >
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
        <form :if={@editable} phx-change="update_event_title" phx-target={@myself} phx-submit="update_event_title" class="pr-8">
          <input
            type="text"
            id="event-title-input"
            name="value"
            value={@selected_event.title || ""}
            placeholder="(No title)"
            phx-blur="update_event_title"
            phx-target={@myself}
            phx-debounce="500"
            class="w-full bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-2xl font-black text-tymeslot-900 tracking-tight px-0 py-0 placeholder:text-tymeslot-400 transition-colors cursor-text"
          />
        </form>
        <h3 :if={!@editable} class="text-token-2xl font-black text-tymeslot-900 tracking-tight pr-8">
          <%= @selected_event.title || "(No title)" %>
        </h3>
      </div>

      <div class={"h-1 rounded-full w-10 mb-2 #{Helpers.color_for_event(assigns, @selected_event)}"}></div>

      <%!-- Time --%>
      <div class="flex items-start gap-3 mb-3">
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" title="Time">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
        </svg>
        <div class="flex-1">
          <% start_parts = Helpers.datetime_to_local_parts(@selected_event.start_at, @user_timezone) %>
          <% end_parts = Helpers.datetime_to_local_parts(@selected_event.end_at, @user_timezone) %>
          <form :if={@editable and not @selected_event.all_day} phx-change="update_event_time" phx-target={@myself} class="flex flex-wrap items-center gap-1 text-token-sm">
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
          <div :if={!@editable or @selected_event.all_day}>
            <p class="text-token-sm font-medium text-tymeslot-700">
              <span :if={@selected_event.all_day}>All day</span>
              <span :if={!@selected_event.all_day}>
                <%= Helpers.format_time_range_in_tz(@selected_event, @user_timezone, @time_format) %>
                <span class="text-token-xs font-normal text-tymeslot-400 ml-1"><%= Helpers.tz_abbr(@user_timezone) %></span>
              </span>
            </p>
            <p class="text-token-xs text-tymeslot-400 mt-0.5">
              <%= Calendar.strftime(@selected_event.start_at |> DateTime.shift_zone!(@user_timezone) |> DateTime.to_date(), "%A, %B %-d") %>
            </p>
          </div>
        </div>
      </div>

      <%!-- Location --%>
      <div :if={@editable} class="flex items-start gap-3 mb-3">
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" title="Location">
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
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
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
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" title="Description">
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
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h7" />
        </svg>
        <div class="text-token-sm text-tymeslot-600 max-h-52 overflow-y-auto whitespace-pre-line break-words flex-1 leading-relaxed">
          <%= Helpers.linkify_text(@selected_event.description) %>
        </div>
      </div>

      <%!-- Attendees --%>
      <div :if={not Enum.empty?(@selected_event.attendees || [])} class="flex items-start gap-3">
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" title="Attendees">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0z" />
        </svg>
        <div class="flex-1">
          <div :for={attendee <- Enum.take(@selected_event.attendees, 5)} class="text-token-sm text-tymeslot-700 leading-snug">
            <%= attendee["name"] || attendee["email"] %>
            <span :if={attendee["name"] && attendee["email"] && attendee["name"] != attendee["email"]} class="text-token-xs text-tymeslot-400 ml-1"><%= attendee["email"] %></span>
          </div>
          <p :if={length(@selected_event.attendees) > 5} class="text-token-xs text-tymeslot-400 mt-1">+<%= length(@selected_event.attendees) - 5 %> more</p>
        </div>
      </div>

      <%!-- Calendar picker --%>
      <div :if={@editable} class="flex items-start gap-3 mb-3">
        <svg class="w-4 h-4 text-tymeslot-400 mt-0.5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" title="Calendar">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z" />
        </svg>
        <div class="flex-1">
          <.calendar_picker
            integrations={@integrations}
            integration_colors={@integration_colors}
            selected_integration_id={@selected_event.calendar_integration_id}
            selected_calendar_id={derive_event_calendar_id(@selected_event, Enum.find(@integrations, &(&1.id == @selected_event.calendar_integration_id)))}
            myself={@myself}
            event_name="update_event_calendar"
          />
        </div>
      </div>

      <%!-- Delete button --%>
      <div :if={@editable} class="mt-4 pt-3 border-t border-tymeslot-100">
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

  attr :event, :map, required: true
  attr :deleting, :boolean, default: false
  attr :myself, :any, required: true

  @spec confirm_delete_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def confirm_delete_modal(assigns) do
    ~H"""
    <.modal
      id="confirm-delete-event-modal"
      show={true}
      on_cancel={JS.push("cancel_delete_event", target: @myself)}
      size={:small}
    >
      <:header>Delete event</:header>

      <p class="text-token-sm text-tymeslot-500">
        Are you sure you want to delete
        <span class="font-medium text-tymeslot-700"><%= @event.title || "(No title)" %></span>?
        This will also remove it from your calendar provider.
      </p>

      <:footer>
        <div class="flex gap-2">
          <.loading_button
            variant={:danger}
            loading={@deleting}
            loading_text="Deleting..."
            phx-click="confirm_delete_event"
            phx-target={@myself}
          >
            Delete
          </.loading_button>
          <.action_button
            variant={:secondary}
            disabled={@deleting}
            phx-click={JS.push("cancel_delete_event", target: @myself)}
          >
            Cancel
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end

  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :selected_integration_id, :integer, required: true
  attr :selected_calendar_id, :string, default: nil
  attr :myself, :any, required: true
  attr :event_name, :string, required: true

  defp calendar_picker(assigns) do
    ~H"""
    <div class="space-y-3">
      <div :for={integration <- @integrations}>
        <% calendars = selected_calendars(integration) %>
        <% is_active_integration = integration.id == @selected_integration_id %>
        <%!-- Integration header --%>
        <div class="flex items-center gap-1.5 mb-1.5">
          <div class={"w-2 h-2 rounded-full flex-shrink-0 #{Helpers.color_dot(%{integration_colors: @integration_colors}, integration)}"}></div>
          <ProviderIcon.provider_icon provider={integration.provider} type="calendar" size="mini" />
          <span class="text-token-xs font-semibold text-tymeslot-500 uppercase tracking-wide truncate">
            <%= integration.name %>
          </span>
        </div>

        <%!-- Calendar buttons --%>
        <% fallback_id = default_calendar_id(calendars) %>
        <div :if={calendars != []} class="flex flex-wrap gap-1.5 pl-3.5">
          <% cal_id = fn cal -> cal["id"] || cal[:id] end %>
          <% cal_name = fn cal -> CalendarIntegration.extract_calendar_display_name(cal) end %>
          <% is_selected = fn cal -> is_active_integration and calendar_selected?(cal_id.(cal), @selected_calendar_id, fallback_id) end %>
          <button
            :for={cal <- calendars}
            type="button"
            phx-click={@event_name}
            phx-value-integration-id={integration.id}
            phx-value-calendar-id={cal_id.(cal)}
            phx-target={@myself}
            class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border text-token-xs transition-all #{if is_selected.(cal), do: "border-turquoise-400 bg-turquoise-50 text-turquoise-800 shadow-sm font-semibold", else: "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"}"}
            title={cal_name.(cal)}
          >
            <div :if={cal["color"] || cal[:color]} class="w-2 h-2 rounded-full flex-shrink-0" style={"background-color: #{cal["color"] || cal[:color]}"}></div>
            <span class="truncate max-w-[10rem]"><%= cal_name.(cal) %></span>
            <span :if={cal["primary"] || cal[:primary]} class="text-token-xs font-bold bg-tymeslot-200 px-1 py-0.5 rounded text-tymeslot-500 uppercase">Primary</span>
          </button>
        </div>
        <%!-- Fallback: integration with no calendar list (single calendar) --%>
        <div :if={calendars == []} class="pl-3.5">
          <button
            type="button"
            phx-click={@event_name}
            phx-value-integration-id={integration.id}
            phx-target={@myself}
            class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border text-token-xs transition-all #{if is_active_integration, do: "border-turquoise-400 bg-turquoise-50 text-turquoise-800 shadow-sm font-semibold", else: "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"}"}
          >
            <span>Default calendar</span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp selected_calendars(integration) do
    Enum.filter(integration.calendar_list || [], &(&1["selected"] || &1[:selected]))
  end

  defp calendar_selected?(cal_id, selected_id, default_id) do
    if is_binary(selected_id), do: cal_id == selected_id, else: cal_id == default_id
  end

  defp default_calendar_id([]), do: nil

  defp default_calendar_id(calendars) do
    primary = Enum.find(calendars, &(&1["primary"] || &1[:primary]))
    cal = primary || List.first(calendars)
    cal["id"] || cal[:id]
  end

  @doc """
  Derives which calendar ID within an integration an event belongs to.

  For Google: matches organizer email from raw_data against calendar list IDs.
  For CalDAV: matches the calendar path prefix in provider_event_id.
  Falls back to default_booking_calendar_id or first calendar.
  """
  @spec derive_event_calendar_id(map(), map() | nil) :: String.t() | nil
  def derive_event_calendar_id(_event, nil), do: nil

  def derive_event_calendar_id(event, integration) do
    calendars = integration.calendar_list || []

    derived =
      cond do
        is_map(event.raw_data) && is_map(event.raw_data["organizer"]) ->
          find_google_calendar_id(calendars, event.raw_data["organizer"]["email"])

        is_binary(event.provider_event_id) ->
          find_caldav_calendar_id(calendars, event.provider_event_id)

        true ->
          nil
      end

    derived || EditWorkflow.default_calendar_id_for(integration)
  end

  defp find_google_calendar_id(calendars, organizer_email) do
    match = Enum.find(calendars, fn c -> (c["id"] || c[:id]) == organizer_email end)
    if match, do: match["id"] || match[:id]
  end

  defp find_caldav_calendar_id(calendars, provider_event_id) do
    match =
      Enum.find(calendars, fn c ->
        path = c["path"] || c[:path] || c["id"] || c[:id]
        is_binary(path) and String.starts_with?(provider_event_id, path)
      end)

    if match, do: match["id"] || match[:id]
  end

  @allowed_atoms %{
    "monday" => :monday,
    "sunday" => :sunday,
    "12h" => :"12h",
    "24h" => :"24h",
    "day" => :day,
    "week" => :week,
    "month" => :month
  }

  defp safe_to_atom(value, default) when is_binary(value) do
    Map.get(@allowed_atoms, value, default)
  end

  defp safe_to_atom(_value, default), do: default
end
