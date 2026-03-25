defmodule TymeslotWeb.Dashboard.MeetingSettings.Components do
  @moduledoc """
  Reusable components for meeting scheduling settings.
  Includes buffer time, advance booking, and minimum notice settings.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router,
    statics: TymeslotWeb.static_paths()

  alias Phoenix.LiveView.JS
  alias Tymeslot.DatabaseSchemas.MeetingTypeSchema
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Utils.ReminderUtils
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers
  import TymeslotWeb.Components.Icons.ProviderIcon

  @doc """
  Component for configuring buffer time between appointments.
  """
  attr :profile, :map, required: true
  attr :myself, :any, required: true
  attr :custom_mode, :boolean, required: true

  @spec buffer_minutes_setting(map()) :: Phoenix.LiveView.Rendered.t()
  def buffer_minutes_setting(assigns) do
    assigns =
      assign(
        assigns,
        :buffer_value,
        if(assigns.profile, do: assigns.profile.buffer_minutes, else: 0)
      )

    ~H"""
    <div>
      <label class="label">
        Buffer Between Appointments
      </label>

    <!-- Tag-based Selection -->
      <form phx-change="update_buffer_minutes" phx-debounce="300" phx-target={@myself}>
      <div class="flex flex-wrap items-center gap-3">
        <!-- Quick preset tags -->
        <%= for minutes <- [0, 5, 10, 15, 30, 60] do %>
          <button
            type="button"
            phx-click="update_buffer_minutes"
            phx-value-buffer_minutes={minutes}
            phx-value-_preset="true"
            phx-target={@myself}
            class={[
              "btn-tag-selector btn-tag-selector-primary",
              if(@buffer_value == minutes and not @custom_mode, do: "btn-tag-selector-primary--active")
            ]}
          >
            <%= if minutes == 0 do %>
              No buffer
            <% else %>
              {minutes} min
            <% end %>
          </button>
        <% end %>

    <!-- Custom input tag -->
        <%= if @custom_mode or @buffer_value not in [0, 5, 10, 15, 30, 60] do %>
          <div class="btn-tag-selector btn-tag-selector-primary--active !p-0 overflow-hidden">
            <input
              type="number"
              min="0"
              max="120"
              step="5"
              value={@buffer_value}
              name="buffer_minutes"
              class="w-20 px-3 py-2 text-token-sm font-black bg-transparent border-0 focus:ring-0 focus:outline-none rounded-l-xl"
              placeholder="0"
            />
            <span class="pr-3 py-2 text-token-sm font-black text-turquoise-700">
              min
            </span>
          </div>
        <% else %>
          <button
            type="button"
            phx-click="focus_custom_input"
            phx-value-setting="buffer_minutes"
            phx-target={@myself}
            class="btn-tag-selector btn-tag-selector-primary"
          >
            Custom
          </button>
        <% end %>
      </div>
      </form>

      <p class="mt-4 text-token-sm text-tymeslot-500 font-bold">
        Time to block after each appointment for preparation, travel, or breaks.
      </p>
    </div>
    """
  end

  @doc """
  Component for configuring how far in advance appointments can be booked.
  """
  attr :profile, :map, required: true
  attr :myself, :any, required: true
  attr :custom_mode, :boolean, required: true

  @spec advance_booking_days_setting(map()) :: Phoenix.LiveView.Rendered.t()
  def advance_booking_days_setting(assigns) do
    assigns =
      assign(
        assigns,
        :booking_days,
        if(assigns.profile, do: assigns.profile.advance_booking_days, else: 90)
      )

    ~H"""
    <div>
      <label class="label">
        How Far in Advance Can People Book
      </label>

    <!-- Tag-based Selection -->
      <form phx-change="update_advance_booking_days" phx-debounce="300" phx-target={@myself}>
      <div class="flex flex-wrap items-center gap-3">
        <!-- Quick preset tags -->
        <%= for {days, label} <- [
          {7, "1 week"},
          {14, "2 weeks"},
          {30, "1 month"},
          {60, "2 months"},
          {90, "3 months"},
          {180, "6 months"}
        ] do %>
          <button
            type="button"
            phx-click="update_advance_booking_days"
            phx-value-advance_booking_days={days}
            phx-value-_preset="true"
            phx-target={@myself}
            class={[
              "btn-tag-selector btn-tag-selector-secondary",
              if(@booking_days == days and not @custom_mode, do: "btn-tag-selector-secondary--active")
            ]}
          >
            {label}
          </button>
        <% end %>
        
    <!-- Custom input tag -->
        <%= if @custom_mode or @booking_days not in [7, 14, 30, 60, 90, 180] do %>
          <div class="btn-tag-selector btn-tag-selector-secondary--active !p-0 overflow-hidden">
            <input
              type="number"
              min="1"
              max="365"
              step="1"
              value={@booking_days}
              name="advance_booking_days"
              class="w-20 px-3 py-2 text-token-sm font-black bg-transparent border-0 focus:ring-0 focus:outline-none rounded-l-xl"
              placeholder="90"
            />
            <span class="pr-3 py-2 text-token-sm font-black text-cyan-700">
              days
            </span>
          </div>
        <% else %>
          <button
            type="button"
            phx-click="focus_custom_input"
            phx-value-setting="advance_booking_days"
            phx-target={@myself}
            class="btn-tag-selector btn-tag-selector-secondary"
          >
            Custom
          </button>
        <% end %>
      </div>
      </form>

      <p class="mt-4 text-token-sm text-tymeslot-500 font-bold">
        Maximum number of days into the future that appointments can be booked.
      </p>
    </div>
    """
  end

  @doc """
  Component for configuring minimum booking notice required.
  """
  attr :profile, :map, required: true
  attr :myself, :any, required: true
  attr :custom_mode, :boolean, required: true

  @spec min_advance_hours_setting(map()) :: Phoenix.LiveView.Rendered.t()
  def min_advance_hours_setting(assigns) do
    assigns =
      assign(
        assigns,
        :notice_hours,
        if(assigns.profile, do: assigns.profile.min_advance_hours, else: 24)
      )

    ~H"""
    <div>
      <label class="label">
        Minimum Booking Notice
      </label>

    <!-- Tag-based Selection -->
      <form phx-change="update_min_advance_hours" phx-debounce="300" phx-target={@myself}>
      <div class="flex flex-wrap items-center gap-3">
        <!-- Quick preset tags -->
        <%= for {hours, label} <- [
          {0, "instant"},
          {1, "1 hour"},
          {4, "4 hours"},
          {24, "1 day"},
          {48, "2 days"},
          {168, "1 week"}
        ] do %>
          <button
            type="button"
            phx-click="update_min_advance_hours"
            phx-value-min_advance_hours={hours}
            phx-value-_preset="true"
            phx-target={@myself}
            class={[
              "btn-tag-selector btn-tag-selector-tertiary",
              if(@notice_hours == hours and not @custom_mode, do: "btn-tag-selector-tertiary--active")
            ]}
          >
            {label}
          </button>
        <% end %>
        
    <!-- Custom input tag -->
        <%= if @custom_mode or @notice_hours not in [0, 1, 4, 24, 48, 168] do %>
          <div class="btn-tag-selector btn-tag-selector-tertiary--active !p-0 overflow-hidden">
            <input
              type="number"
              min="0"
              max="168"
              step="1"
              value={@notice_hours}
              name="min_advance_hours"
              class="w-20 px-3 py-2 text-token-sm font-black bg-transparent border-0 focus:ring-0 focus:outline-none rounded-l-xl"
              placeholder="24"
            />
            <span class="pr-3 py-2 text-token-sm font-black text-blue-700">
              hours
            </span>
          </div>
        <% else %>
          <button
            type="button"
            phx-click="focus_custom_input"
            phx-value-setting="min_advance_hours"
            phx-target={@myself}
            class="btn-tag-selector btn-tag-selector-tertiary"
          >
            Custom
          </button>
        <% end %>
      </div>
      </form>

      <p class="mt-4 text-token-sm text-tymeslot-500 font-bold">
        Minimum hours of notice required before an appointment can be booked.
      </p>
    </div>
    """
  end

  @doc """
  Section for configuring meeting reminders.
  """
  attr :reminders, :list, required: true
  attr :new_reminder_value, :string, required: true
  attr :new_reminder_unit, :string, required: true
  attr :reminder_error, :string, required: true
  attr :show_custom_reminder, :boolean, default: false
  attr :reminder_confirmation, :string, default: nil
  attr :form_errors, :map, required: true
  attr :myself, :any, required: true

  @spec reminders_section(map()) :: Phoenix.LiveView.Rendered.t()
  def reminders_section(assigns) do
    ~H"""
    <div>
      <label class="label">
        Reminders
      </label>
      <p class="text-token-sm text-tymeslot-600">
        Add up to three reminder emails for this meeting type. We recommend using only one.
      </p>
      
      <div class="mt-3 flex flex-wrap items-center gap-3">
        <%= if @reminders == [] do %>
          <span class="text-token-sm text-tymeslot-500 italic">No reminders configured.</span>
        <% else %>
          <%= for reminder <- @reminders do %>
            <span class="tag-semantic tag-semantic-teal animate-in zoom-in duration-300">
              {ReminderUtils.format_reminder_label(reminder.value, reminder.unit)} before
              <button
                type="button"
                phx-click={JS.push("remove_reminder",
                  value: %{value: reminder.value, unit: reminder.unit},
                  target: @myself
                )}
                class="inline-flex items-center justify-center rounded-full border border-teal-200 bg-white text-teal-600 hover:text-teal-700 hover:border-teal-300"
                aria-label="Remove reminder"
              >
                <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            </span>
          <% end %>
        <% end %>
      </div>

      <div class="mt-4 space-y-3">
        <div class="flex flex-wrap items-center gap-2">
          <!-- Quick add buttons -->
          <%= unless Enum.any?(@reminders, &(&1.value == 30 and &1.unit == "minutes")) do %>
            <button
              type="button"
              phx-click={JS.push("add_quick_reminder", value: %{amount: 30, unit: "minutes"}, target: @myself)}
              disabled={length(@reminders) >= 3}
              title={if length(@reminders) >= 3, do: "Maximum of 3 reminders allowed", else: nil}
              class="btn-tag-selector btn-tag-selector-teal"
            >
              + 30 min. before
            </button>
          <% end %>
          
          <%= unless Enum.any?(@reminders, &(&1.value == 60 and &1.unit == "minutes") or (&1.value == 1 and &1.unit == "hours")) do %>
            <button
              type="button"
              phx-click={JS.push("add_quick_reminder", value: %{amount: 60, unit: "minutes"}, target: @myself)}
              disabled={length(@reminders) >= 3}
              title={if length(@reminders) >= 3, do: "Maximum of 3 reminders allowed", else: nil}
              class="btn-tag-selector btn-tag-selector-teal"
            >
              + 1 hour before
            </button>
          <% end %>

          <button
            type="button"
            phx-click="toggle_custom_reminder"
            phx-target={@myself}
            disabled={length(@reminders) >= 3}
            title={if length(@reminders) >= 3, do: "Maximum of 3 reminders allowed", else: nil}
            class={[
              "btn-tag-selector btn-tag-selector-teal",
              if(@show_custom_reminder, do: "btn-tag-selector-teal--active")
            ]}
          >
            {if @show_custom_reminder, do: "Cancel Custom", else: "Add Custom"}
          </button>

          <%= if @reminder_confirmation do %>
            <span class="text-token-sm text-teal-600 font-bold animate-in fade-in slide-in-from-left-2 duration-500">
              ✓ {@reminder_confirmation}
            </span>
          <% end %>
        </div>

        <%= if @show_custom_reminder && length(@reminders) < 3 do %>
          <div class="flex items-center gap-2 p-3 bg-teal-50/50 rounded-token-2xl border-2 border-teal-100/50 max-w-sm animate-in slide-in-from-top-2 duration-300">
            <div class="flex-1 flex items-center gap-2">
              <input
                type="number"
                min="1"
                step="1"
                name="reminder[value]"
                value={@new_reminder_value}
                placeholder="30"
                class="input !py-1.5 !px-3 w-20 text-token-sm"
                phx-change="update_reminder_input"
                phx-target={@myself}
              />
              <select
                name="reminder[unit]"
                class="input !py-1.5 !px-3 w-28 text-token-sm"
                value={@new_reminder_unit}
                phx-change="update_reminder_input"
                phx-target={@myself}
              >
                <option value="minutes">Minutes</option>
                <option value="hours">Hours</option>
                <option value="days">Days</option>
              </select>
            </div>
            <button
              type="button"
              phx-click="add_reminder"
              phx-target={@myself}
              class="btn btn-primary btn-sm !rounded-token-lg"
            >
              Add
            </button>
          </div>
        <% end %>
      </div>

      <%= if @reminder_error do %>
        <p class="form-error mt-2">{@reminder_error}</p>
      <% end %>
      <%= for error <- FormValidationHelpers.field_errors(@form_errors, :reminder_config) do %>
        <p class="form-error mt-2">{Helpers.format_errors(error)}</p>
      <% end %>
    </div>
    """
  end

  @doc """
  Picker for choosing a meeting type icon.
  """
  attr :selected_icon, :string, required: true
  attr :form_errors, :map, required: true
  attr :myself, :any, required: true

  @spec icon_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def icon_picker(assigns) do
    ~H"""
    <div>
      <label class="label">
        Icon
      </label>
      <div class="grid grid-cols-8 sm:grid-cols-10 md:grid-cols-14 lg:grid-cols-16 gap-1">
        <%= for {icon_value, icon_name} <- MeetingTypeSchema.valid_icons_with_names() do %>
          <button
            type="button"
            phx-click={JS.push("select_icon", value: %{icon: icon_value}, target: @myself)}
            class={[
              "relative rounded-token-md border-2 transition-colors duration-200 group",
              "w-10 h-10 flex items-center justify-center overflow-hidden",
              if(@selected_icon == icon_value,
                do: "bg-gradient-to-br from-teal-50 to-teal-100 border-teal-500 shadow-md",
                else: "bg-white/50 border-tymeslot-300/50 hover:border-teal-400/50 hover:bg-white/70"
              )
            ]}
            style="width: 40px; height: 40px; min-width: 40px; min-height: 40px; max-width: 40px; max-height: 40px;"
            title={icon_name}
          >
            <%= if icon_value == "none" do %>
              <svg
                class="w-6 h-6 text-tymeslot-400"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            <% else %>
              <span
                class={[
                  icon_value,
                  "block",
                  if(@selected_icon == icon_value,
                    do: "text-teal-600",
                    else: "text-tymeslot-500 group-hover:text-teal-500"
                  )
                ]}
                style="width: 32px; height: 32px; min-width: 32px; min-height: 32px;"
              />
            <% end %>
          </button>
        <% end %>
      </div>
      <p class="mt-2 text-token-sm text-tymeslot-600">
        Choose an icon to represent this meeting type, or select "No Icon" for no visual indicator.
      </p>
      <%= for error <- FormValidationHelpers.field_errors(@form_errors, :icon) do %>
        <p class="form-error">{Helpers.format_errors(error)}</p>
      <% end %>
    </div>
    """
  end

  @doc """
  Section for selecting meeting mode (Personal vs Video).
  """
  attr :meeting_mode, :string, required: true
  attr :video_integrations, :list, required: true
  attr :selected_video_integration_id, :any, required: true
  attr :form_errors, :map, required: true
  attr :myself, :any, required: true
  attr :icon_size, :string, default: "compact", values: ["compact", "medium", "large", "mini"]

  @spec meeting_mode_section(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_mode_section(assigns) do
    ~H"""
    <div>
      <label class="label">
        Meeting Type
      </label>
      <div class="flex items-center space-x-4">
        <button
          type="button"
          phx-click={JS.push("toggle_meeting_mode", value: %{mode: "personal"}, target: @myself)}
          class={[
            "glass-selector",
            if(@meeting_mode == "personal", do: "glass-selector--active")
          ]}
        >
          <div class="flex items-center justify-center">
            <span class={[
              "hero-user selector-icon",
              if(@meeting_mode == "personal", do: "!text-white")
            ]} />
            <span class="font-medium">In-Person</span>
          </div>
        </button>

        <button
          type="button"
          phx-click={JS.push("toggle_meeting_mode", value: %{mode: "video"}, target: @myself)}
          class={[
            "glass-selector",
            if(@meeting_mode == "video", do: "glass-selector--active")
          ]}
        >
          <div class="flex items-center justify-center">
            <span class={[
              "hero-video-camera selector-icon",
              if(@meeting_mode == "video", do: "!text-white")
            ]} />
            <span class="font-medium">Video Meeting</span>
          </div>
        </button>
      </div>

      <%= if @meeting_mode == "video" do %>
        <div class="mt-4">
          <label class="label text-token-sm">
            Select Video Provider
          </label>
          <%= if @video_integrations == [] do %>
            <div class="p-4 bg-yellow-500/10 border border-yellow-500/30 rounded-token-lg">
              <p class="text-token-sm text-yellow-700">
                No video integrations configured.
                <a href={~p"/dashboard/video-integrations"} class="underline hover:text-yellow-800">
                  Set up video integration
                </a>
              </p>
            </div>
          <% else %>
            <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-2">
              <%= for integration <- @video_integrations do %>
                <button
                  type="button"
                  phx-click={
                    JS.push("select_video_integration",
                      value: %{id: integration.id},
                      target: @myself
                    )
                  }
                  class={[
                    "glass-selector !h-20",
                    if(@selected_video_integration_id == integration.id, do: "glass-selector--active")
                  ]}
                  title={integration.name}
                >
                  <div class="flex flex-col items-center justify-center space-y-1">
                    <.provider_icon provider={integration.provider} size={@icon_size} />
                    <span class="text-token-sm font-medium truncate max-w-full">{integration.name}</span>
                    <span :if={integration.provider_account_email} class="text-token-xs text-muted truncate max-w-full">
                      {integration.provider_account_email}
                    </span>
                  </div>
                </button>
              <% end %>
            </div>
            <%= for error <- FormValidationHelpers.field_errors(@form_errors, :video_integration) do %>
              <p class="form-error mt-2">{Helpers.format_errors(error)}</p>
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Section for selecting the booking destination calendar.
  """
  attr :calendar_integrations, :list, required: true
  attr :selected_calendar_integration_id, :any, required: true
  attr :refreshing_calendars, :boolean, required: true
  attr :available_calendars, :list, required: true
  attr :selected_target_calendar_id, :any, required: true
  attr :form_errors, :map, required: true
  attr :myself, :any, required: true
  attr :icon_size, :string, default: "compact", values: ["compact", "medium", "large", "mini"]

  @spec booking_destination_section(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_destination_section(assigns) do
    ~H"""
    <div class="pt-4 border-t border-tymeslot-100">
      <label class="label">
        Booking Destination
      </label>
      <p class="text-token-sm text-tymeslot-600 mb-4">
        Choose where new bookings for this meeting type should be created.
      </p>

      <div class="space-y-4">
        <div>
          <label class="label text-token-sm">
            1. Select Calendar Account
          </label>
          <%= if @calendar_integrations == [] do %>
            <div class="p-4 bg-yellow-500/10 border border-yellow-500/30 rounded-token-lg">
              <p class="text-token-sm text-yellow-700">
                No calendar integrations configured.
                <a href={~p"/dashboard/calendar"} class="underline hover:text-yellow-800">
                  Connect a calendar
                </a>
              </p>
            </div>
          <% else %>
            <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-2">
              <%= for integration <- @calendar_integrations do %>
                <button
                  type="button"
                  disabled={@refreshing_calendars}
                  phx-click={
                    JS.push("select_calendar_integration",
                      value: %{id: integration.id},
                      target: @myself
                    )
                  }
                  class={[
                    "glass-selector !h-20",
                    if(@selected_calendar_integration_id == integration.id, do: "glass-selector--active"),
                    if(not integration.is_active, do: "opacity-60"),
                    if(@refreshing_calendars, do: "opacity-50 cursor-not-allowed")
                  ]}
                  title={integration.name}
                >
                  <div class="flex flex-col items-center justify-center space-y-1">
                    <.provider_icon provider={integration.provider} size={@icon_size} />
                    <span class="text-token-sm font-medium truncate max-w-full">
                      {integration.name}
                    </span>
                    <%= if not integration.is_active do %>
                      <span class="text-[10px] font-semibold text-amber-600 bg-amber-50 px-1.5 py-0.5 rounded-full leading-tight">
                        Reconnect
                      </span>
                    <% end %>
                  </div>
                </button>
              <% end %>
            </div>
            <%= for error <- FormValidationHelpers.field_errors(@form_errors, :calendar_integration) do %>
              <p class="form-error mt-2">{Helpers.format_errors(error)}</p>
            <% end %>
          <% end %>
        </div>

        <%= if @selected_calendar_integration_id do %>
          <div class="animate-in fade-in slide-in-from-top-2 duration-300">
            <label class="label text-token-sm">
              2. Select Specific Calendar
            </label>
            <%= if @refreshing_calendars do %>
              <div class="flex items-center space-x-2 p-4 bg-tymeslot-50 rounded-token-lg">
                <svg class="animate-spin h-4 w-4 text-teal-600" fill="none" viewBox="0 0 24 24">
                  <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                  <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                </svg>
                <span class="text-token-sm text-tymeslot-600 font-medium italic">Refreshing calendars...</span>
              </div>
            <% else %>
              <%= if @available_calendars == [] do %>
                <p class="text-token-sm text-tymeslot-500 italic">
                  No calendars found for this account.
                </p>
              <% else %>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                  <%= for cal <- @available_calendars do %>
                    <button
                      type="button"
                      phx-click={
                        JS.push("select_target_calendar",
                          value: %{id: cal["id"] || cal[:id]},
                          target: @myself
                        )
                      }
                      class={[
                        "flex items-center p-3 rounded-token-lg border-2 transition-all text-left",
                        if(@selected_target_calendar_id == (cal["id"] || cal[:id]),
                          do: "bg-teal-50 border-teal-500 shadow-sm",
                          else: "bg-white border-tymeslot-100 hover:border-teal-200"
                        )
                      ]}
                    >
                      <div class={[
                        "w-4 h-4 rounded-full border-2 mr-3 flex items-center justify-center",
                        if(@selected_target_calendar_id == (cal["id"] || cal[:id]),
                          do: "border-teal-50 bg-teal-500",
                          else: "border-tymeslot-300"
                        )
                      ]}>
                        <%= if @selected_target_calendar_id == (cal["id"] || cal[:id]) do %>
                          <svg class="w-2.5 h-2.5 text-white" fill="currentColor" viewBox="0 0 20 20">
                            <path d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" />
                          </svg>
                        <% end %>
                      </div>
                      <span class={[
                        "text-token-sm font-medium truncate",
                        if(@selected_target_calendar_id == (cal["id"] || cal[:id]),
                          do: "text-teal-900",
                          else: "text-tymeslot-700"
                        )
                      ]}>
                        {Calendar.extract_calendar_display_name(cal)}
                      </span>
                    </button>
                  <% end %>
                </div>
                <%= for error <- FormValidationHelpers.field_errors(@form_errors, :target_calendar) do %>
                  <p class="form-error mt-2">{Helpers.format_errors(error)}</p>
                <% end %>
              <% end %>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
