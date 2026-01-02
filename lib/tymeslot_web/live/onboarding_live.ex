defmodule TymeslotWeb.OnboardingLive do
  use TymeslotWeb, :live_view

  import TymeslotWeb.Components.CoreComponents
  alias Phoenix.LiveView.JS

  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles.Timezone
  alias Tymeslot.Utils.TimezoneUtils
  alias TymeslotWeb.Components.Auth.AuthVideoConfig
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.OnboardingLive.BasicSettingsHandlers
  alias TymeslotWeb.OnboardingLive.BasicSettingsStep
  alias TymeslotWeb.OnboardingLive.CompleteStep
  alias TymeslotWeb.OnboardingLive.NavigationHandlers
  alias TymeslotWeb.OnboardingLive.SchedulingHandlers
  alias TymeslotWeb.OnboardingLive.SchedulingPreferencesStep
  alias TymeslotWeb.OnboardingLive.StepConfig
  alias TymeslotWeb.OnboardingLive.TimezoneHandlers
  alias TymeslotWeb.OnboardingLive.WelcomeStep

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # Check if this is a debug route by examining the live_action
    is_debug = socket.assigns.live_action in [:debug_welcome, :debug_step]

    # Check if user has already completed onboarding (skip for debug routes)
    if user.onboarding_completed_at && !is_debug do
      socket = put_flash(socket, :info, "You have already completed onboarding.")
      {:ok, redirect(socket, to: ~p"/dashboard")}
    else
      # Handle profile creation
      {:ok, profile} = Onboarding.get_or_create_profile(user.id)

      # Use existing user name if available, otherwise fall back to profile full_name
      default_full_name = user.name || profile.full_name || ""

      # Read detected timezone from connect params (set in assets/js/app.js)
      connect_params = get_connect_params(socket) || %{}
      detected_timezone = connect_params["timezone"]

      # Decide prefill value in the context (pure function, no persistence)
      prefilled_timezone = Timezone.prefill_timezone(profile.timezone, detected_timezone)
      prefilled_profile = Map.put(profile, :timezone, prefilled_timezone)

      socket =
        socket
        |> assign(:profile, prefilled_profile)
        |> assign(:form_data, %{
          "full_name" => default_full_name,
          "username" => profile.username || ""
        })
        |> assign(:current_step, :welcome)
        |> assign(:step_data, %{})
        |> assign(:show_skip_modal, false)
        |> assign(:steps, StepConfig.get_steps())
        |> assign(:timezone_options, TimezoneUtils.get_all_timezone_options())
        |> assign(:timezone_dropdown_open, false)
        |> assign(:timezone_search, "")
        |> assign(:page_title, "Welcome to Tymeslot")
        |> assign(:form_errors, %{})
        |> assign(:remote_ip, ClientIP.get(socket))

      {:ok, socket}
    end
  end

  @impl true
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(%{"step" => step}, _uri, socket) do
    if StepConfig.valid_step?(step) do
      step_atom = String.to_existing_atom(step)
      {:noreply, assign(socket, :current_step, step_atom)}
    else
      # Preserve debug route when redirecting
      redirect_path =
        if socket.assigns.live_action in [:debug_welcome, :debug_step] do
          ~p"/debug/onboarding"
        else
          ~p"/onboarding"
        end

      {:noreply, redirect(socket, to: redirect_path)}
    end
  end

  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :current_step, :welcome)}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <.flash_group flash={@flash} id="flash-group" />
    <main class="glass-theme">
      <!-- Enhanced Video Background with Multiple Sources -->
      <div class="video-background-container" id="auth-video-container" phx-hook="AuthVideo">
        <video
          class="video-background-video"
          autoplay
          loop
          muted
          playsinline
          preload="metadata"
          poster={AuthVideoConfig.auth_video_poster()}
          id="auth-background-video"
        >
          <%= for video <- AuthVideoConfig.auth_video_sources() do %>
            <source
              src={video.src}
              type={video.type}
              {if video.media, do: [media: video.media], else: []}
            />
          <% end %>
          <!-- Fallback gradient background -->
          <div
            class="absolute inset-0"
            style={"background: #{AuthVideoConfig.auth_fallback_gradient()}"}
          >
          </div>
        </video>
      </div>

      <div class="glass-container">
        <div class="flex-1 flex items-center justify-center py-4 sm:py-6 md:py-8">
          <div class="w-full max-w-2xl">
            <!-- Progress indicator with enhancements -->
            <div class="progress-indicator">
              <div class="progress-indicator-container">
                <%= for {step, index} <- Enum.with_index(@steps) do %>
                  <div class="progress-step">
                    <div class={[
                      "progress-step-circle",
                      if(StepConfig.step_completed?(step, @current_step),
                        do: "progress-step-circle--completed",
                        else:
                          if(step == @current_step,
                            do: "progress-step-circle--active",
                            else: "progress-step-circle--inactive"
                          )
                      )
                    ]}>
                      <%= if StepConfig.step_completed?(step, @current_step) do %>
                        <.icon name="hero-check" class="w-5 h-5" />
                      <% else %>
                        {index + 1}
                      <% end %>
                    </div>

                    <%= if index < length(@steps) - 1 do %>
                      <div class={[
                        "progress-step-connector",
                        if(StepConfig.step_completed?(step, @current_step),
                          do: "progress-step-connector--completed",
                          else: "progress-step-connector--inactive"
                        )
                      ]}>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
            
    <!-- Main content card with enhanced glass -->
            <div class="glass-card-base-wide animate-fade-in-subtle">
              <%= case @current_step do %>
                <% :welcome -> %>
                  <WelcomeStep.welcome_step />
                <% :basic_settings -> %>
                  <BasicSettingsStep.basic_settings_step
                    profile={@profile}
                    form_data={@form_data}
                    timezone_options={@timezone_options}
                    timezone_dropdown_open={@timezone_dropdown_open}
                    timezone_search={@timezone_search}
                    form_errors={@form_errors}
                  />
                <% :scheduling_preferences -> %>
                  <SchedulingPreferencesStep.scheduling_preferences_step
                    profile={@profile}
                    form_errors={@form_errors}
                  />
                <% :complete -> %>
                  <CompleteStep.complete_step />
              <% end %>
              
    <!-- Navigation buttons -->
              <div class="flex justify-between mt-8">
                <button type="button" phx-click="show_skip_modal" class="btn-ghost glass-button">
                  Skip setup
                </button>

                <div class="flex space-x-4">
                  <%= if @current_step != :welcome do %>
                    <button type="button" phx-click="previous_step" class="btn-secondary">
                      Previous
                    </button>
                  <% end %>

                  <button type="button" phx-click="next_step" class="btn-primary">
                    {StepConfig.next_button_text(@current_step)}
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Skip confirmation modal -->
      <.modal
        id="skip-onboarding-modal"
        show={@show_skip_modal}
        on_cancel={JS.push("hide_skip_modal")}
      >
        <:header>
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-yellow-600" /> Skip Onboarding?
        </:header>

        <div class="text-center py-2">
          <p class="font-medium" style="color: var(--color-text-glass-primary);">
            Are you sure you want to skip the setup? You can always configure these settings later in your dashboard.
          </p>
        </div>

        <:footer>
          <.action_button
            variant={:secondary}
            phx-click="hide_skip_modal"
            class="text-gray-800 font-semibold"
          >
            Continue Setup
          </.action_button>
          <.action_button
            variant={:primary}
            phx-click="skip_onboarding"
            class="bg-yellow-600 hover:bg-yellow-700 text-white font-semibold"
          >
            Skip Setup
          </.action_button>
        </:footer>
      </.modal>
    </main>
    """
  end

  # Event handlers - Navigation
  @impl true
  def handle_event("next_step", _params, socket) do
    NavigationHandlers.handle_next_step(socket)
  end

  def handle_event("previous_step", _params, socket) do
    NavigationHandlers.handle_previous_step(socket)
  end

  def handle_event("show_skip_modal", _params, socket) do
    NavigationHandlers.handle_show_skip_modal(socket)
  end

  def handle_event("hide_skip_modal", _params, socket) do
    NavigationHandlers.handle_hide_skip_modal(socket)
  end

  def handle_event("skip_onboarding", _params, socket) do
    NavigationHandlers.handle_skip_onboarding(socket)
  end

  # Event handlers - Basic Settings
  def handle_event("validate_basic_settings", params, socket) do
    BasicSettingsHandlers.handle_validate_basic_settings(params, socket)
  end

  def handle_event("update_basic_settings", _params, socket) do
    NavigationHandlers.handle_next_step(socket)
  end

  # Event handlers - Scheduling Preferences
  def handle_event("validate_scheduling_preferences", params, socket) do
    SchedulingHandlers.handle_validate_scheduling_preferences(params, socket)
  end

  def handle_event("update_scheduling_preferences", params, socket) do
    SchedulingHandlers.handle_update_scheduling_preferences(params, socket)
  end

  # Event handlers - Timezone
  def handle_event("toggle_timezone_dropdown", _params, socket) do
    TimezoneHandlers.handle_toggle_timezone_dropdown(socket)
  end

  def handle_event("close_timezone_dropdown", _params, socket) do
    TimezoneHandlers.handle_close_timezone_dropdown(socket)
  end

  def handle_event("search_timezone", %{"search" => search}, socket) do
    TimezoneHandlers.handle_search_timezone(search, socket)
  end

  def handle_event("search_timezone", %{"value" => search}, socket) do
    TimezoneHandlers.handle_search_timezone(search, socket)
  end

  def handle_event("change_timezone", %{"timezone" => timezone}, socket) do
    TimezoneHandlers.handle_change_timezone(timezone, socket)
  end

  # Handle flash messages from components
  @impl true
  def handle_info({:flash, {type, message}}, socket) do
    {:noreply, put_flash(socket, type, message)}
  end
end
