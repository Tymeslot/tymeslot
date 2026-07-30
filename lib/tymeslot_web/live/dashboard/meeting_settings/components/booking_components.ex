defmodule TymeslotWeb.Dashboard.MeetingSettings.Components.BookingComponents do
  @moduledoc "Booking destination and mode components for meeting type forms."
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router,
    statics: TymeslotWeb.static_paths()

  alias Phoenix.LiveView.JS
  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias TymeslotWeb.Components.CoreComponents.Icons
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers
  import TymeslotWeb.Components.CoreComponents, only: [spinner: 1]
  import TymeslotWeb.Components.Icons.ProviderIcon

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
                do: "bg-linear-to-br from-turquoise-50 to-turquoise-100 border-turquoise-500 shadow-md",
                else: "bg-white/50 border-tymeslot-300/50 hover:border-turquoise-400/50 hover:bg-white/70"
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
              <Icons.icon
                name={icon_value}
                class={
                  "w-8 h-8 block " <>
                    if(@selected_icon == icon_value,
                      do: "text-turquoise-600",
                      else: "text-tymeslot-500 group-hover:text-turquoise-500"
                    )
                }
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
            <Icons.icon name="hero-user" class="selector-icon" />
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
            <Icons.icon name="hero-video-camera" class="selector-icon" />
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
                <a href={~p"/dashboard/integrations?tab=video"} class="underline hover:text-yellow-800">
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
                    "glass-selector h-20!",
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
  attr :no_writable_calendars, :boolean, required: true
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
                <a href={~p"/dashboard/integrations?tab=calendars"} class="underline hover:text-yellow-800">
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
                    "glass-selector h-20!",
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
                      <span class="text-token-2xs font-semibold text-amber-600 bg-amber-50 px-1.5 py-0.5 rounded-full leading-tight">
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
                <.spinner class="h-4 w-4 text-turquoise-600" />
                <span class="text-token-sm text-tymeslot-600 font-medium italic">Refreshing calendars...</span>
              </div>
            <% else %>
              <%= if @available_calendars == [] do %>
                <%= if @no_writable_calendars do %>
                  <div class="p-4 bg-yellow-500/10 border border-yellow-500/30 rounded-token-lg">
                    <p class="text-token-sm text-yellow-700">
                      None of the calendars you selected for this account can accept bookings.
                      <a
                        href={~p"/dashboard/integrations?tab=calendars"}
                        class="underline hover:text-yellow-800"
                      >
                        Update your calendar selection
                      </a>
                      or choose a different account.
                    </p>
                  </div>
                <% else %>
                  <p class="text-token-sm text-tymeslot-500 italic">
                    No calendars found for this account.
                  </p>
                <% end %>
              <% else %>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                  <%= for cal <- @available_calendars do %>
                    <button
                      type="button"
                      phx-click={
                        JS.push("select_target_calendar",
                          value: %{id: cal.id},
                          target: @myself
                        )
                      }
                      class={[
                        "flex items-center p-3 rounded-token-lg border-2 transition-all text-left",
                        if(@selected_target_calendar_id == (cal.id),
                          do: "bg-turquoise-50 border-turquoise-500 shadow-sm",
                          else: "bg-white border-tymeslot-100 hover:border-turquoise-200"
                        )
                      ]}
                    >
                      <div class={[
                        "w-4 h-4 rounded-full border-2 mr-3 flex items-center justify-center",
                        if(@selected_target_calendar_id == (cal.id),
                          do: "border-turquoise-50 bg-turquoise-500",
                          else: "border-tymeslot-300"
                        )
                      ]}>
                        <%= if @selected_target_calendar_id == (cal.id) do %>
                          <svg class="w-2.5 h-2.5 text-white" fill="currentColor" viewBox="0 0 20 20">
                            <path d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" />
                          </svg>
                        <% end %>
                      </div>
                      <span class={[
                        "text-token-sm font-medium truncate",
                        if(@selected_target_calendar_id == (cal.id),
                          do: "text-turquoise-900",
                          else: "text-tymeslot-700"
                        )
                      ]}>
                        {DisplayHelpers.extract_calendar_display_name(cal)}
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
