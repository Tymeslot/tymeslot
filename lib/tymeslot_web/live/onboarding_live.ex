defmodule TymeslotWeb.OnboardingLive do
  use TymeslotWeb, :live_view

  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.Timezone
  alias Tymeslot.Timezones
  alias TymeslotWeb.CustomInputModeHelper
  alias TymeslotWeb.OnboardingLive.BasicSettingsHandlers
  alias TymeslotWeb.OnboardingLive.BasicSettingsStep
  alias TymeslotWeb.OnboardingLive.CompleteStep
  alias TymeslotWeb.OnboardingLive.NavigationHandlers
  alias TymeslotWeb.OnboardingLive.SchedulingHandlers
  alias TymeslotWeb.OnboardingLive.SchedulingPreferencesStep
  alias TymeslotWeb.OnboardingLive.SkipConfirmationModal
  alias TymeslotWeb.OnboardingLive.StepConfig
  alias TymeslotWeb.OnboardingLive.TimezoneHandlers
  alias TymeslotWeb.OnboardingLive.WelcomeStep

  @impl Phoenix.LiveView
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

      # Decide prefill value (pure function) and persist immediately so the DB
      # stays in sync with what the UI displays.  Without this, the in-memory
      # struct fools Ecto's change tracking and the timezone never reaches the DB.
      prefilled_timezone = Timezone.prefill_timezone(profile.timezone, detected_timezone)

      profile =
        if prefilled_timezone != profile.timezone do
          case Profiles.update_timezone(profile, prefilled_timezone) do
            {:ok, updated_profile} -> updated_profile
            {:error, _reason} -> Map.put(profile, :timezone, prefilled_timezone)
          end
        else
          profile
        end

      socket =
        socket
        |> assign(:profile, profile)
        |> assign(:form_data, %{
          "full_name" => default_full_name,
          "username" => profile.username || ""
        })
        |> assign(:current_step, :welcome)
        |> assign(:step_data, %{})
        |> assign(:show_skip_modal, false)
        |> assign(:steps, StepConfig.get_steps())
        |> assign(:timezone_options, Timezones.all_options())
        |> assign(:timezone_dropdown_open, false)
        |> assign(:timezone_search, "")
        |> assign(:page_title, "Welcome")
        |> assign(:form_errors, %{})
        |> assign(:custom_input_mode, CustomInputModeHelper.default_custom_mode())

      {:ok, socket}
    end
  end

  @impl Phoenix.LiveView
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

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-gradient-to-br from-turquoise-600 via-cyan-600 to-blue-600 flex items-start sm:items-center justify-center px-4 py-6 sm:p-6 relative overflow-y-auto">
      <!-- Animated background elements -->
      <div class="absolute inset-0 bg-[radial-gradient(circle_at_30%_20%,rgba(255,255,255,0.15),transparent_50%)]"></div>
      <div class="absolute inset-0 bg-[radial-gradient(circle_at_70%_80%,rgba(6,182,212,0.3),transparent_50%)]"></div>

      <div class="w-full max-w-5xl relative z-10 animate-in fade-in zoom-in-95 duration-700">
        <div class="flex-1 flex flex-col items-center">
          <div class="w-full">
            <!-- Progress indicator with enhancements -->
            <div class="progress-indicator">
              <div class="progress-indicator-container">
                <%= for {step, index} <- Enum.with_index(@steps) do %>
                  <div class="flex items-center">
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
                        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M5 13l4 4L19 7" />
                        </svg>
                      <% else %>
                        {index + 1}
                      <% end %>
                    </div>

                    <%= if index < length(@steps) - 1 do %>
                      <div class={[
                        "progress-step-connector",
                        if(StepConfig.step_completed?(step, @current_step),
                          do: "progress-step-connector--completed",
                          else: ""
                        )
                      ]}>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>

    <!-- Main content card -->
            <div class="card-glass">
              <div class="p-6 sm:p-8 lg:p-10">
                <!-- Company logo and name -->
                <div class="flex items-center justify-center mb-6">
                  <TymeslotWeb.Components.CoreComponents.logo
                    mode={:full}
                    img_class="h-14 sm:h-16"
                  />
                </div>

                <div class="animate-in fade-in slide-in-from-bottom-4 duration-500">
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
                      custom_input_mode={@custom_input_mode}
                    />
                  <% :complete -> %>
                    <CompleteStep.complete_step />
                  <% end %>
                </div>

      <!-- Navigation buttons -->
                <div class="flex flex-col sm:flex-row items-center justify-between mt-6 pt-6 border-t-2 border-tymeslot-50 gap-4">
                  <button type="button" phx-click="show_skip_modal" class="text-tymeslot-400 hover:text-tymeslot-600 font-black uppercase tracking-widest text-xs transition-colors">
                    Skip for now
                  </button>

                  <div class="flex items-center gap-3 w-full sm:w-auto">
                    <%= if @current_step != :welcome do %>
                      <button type="button" phx-click="previous_step" class="btn-secondary flex-1 sm:flex-none px-6 py-4 sm:py-3">
                        Back
                      </button>
                    <% end %>

                    <button type="button" phx-click="next_step" class="btn-primary flex-1 sm:flex-none px-8 py-4 sm:py-3">
                      {StepConfig.next_button_text(@current_step)}
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

    <!-- Skip confirmation modal -->
      <SkipConfirmationModal.skip_confirmation_modal show={@show_skip_modal} />
    </main>
    """
  end

  # Event handlers - Navigation
  @impl Phoenix.LiveView
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
    {:noreply, updated_socket} =
      SchedulingHandlers.handle_update_scheduling_preferences(params, socket)

    if Map.get(updated_socket.assigns, :form_errors, %{}) == %{} do
      socket_with_mode = update_custom_input_modes(updated_socket, params)
      {:noreply, socket_with_mode}
    else
      {:noreply, updated_socket}
    end
  end

  @doc """
  Handles clicking the "Custom" button for a scheduling preference field.

  When a preset value is currently selected, switches to a custom input with a
  sensible default value that is not in the preset list. When a custom value is
  already set, preserves that value.

  ## Parameters
  - setting: The field name (e.g., "buffer_minutes", "advance_booking_days")
  - socket: The LiveView socket
  """
  def handle_event("focus_custom_input", %{"setting" => setting}, socket) do
    # Defensive nil checks to prevent crashes with invalid settings or missing profile
    with %{} = config <- StepConfig.custom_input_config()[setting],
         %{} = profile <- socket.assigns[:profile] do
      current = Map.get(profile, config.field) || config.constraints.default_custom

      # If current is a preset, use custom default; otherwise keep current custom value
      custom_value =
        if current in config.presets do
          config.constraints.default_custom
        else
          current
        end

      # Update profile first via handler, then enable custom mode only on success
      params = %{setting => to_string(custom_value)}

      {:noreply, updated_socket} =
        SchedulingHandlers.handle_update_scheduling_preferences(params, socket)

      # Check if update was successful
      if Map.get(updated_socket.assigns, :form_errors, %{}) == %{} do
        # Success - enable custom mode for this field
        socket_with_mode =
          CustomInputModeHelper.enable_custom_mode(updated_socket, config.field)

        {:noreply, socket_with_mode}
      else
        # Validation or update failed - don't enable custom mode
        {:noreply, updated_socket}
      end
    else
      # Invalid setting name or missing profile - return unchanged socket
      _other -> {:noreply, socket}
    end
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
  @impl Phoenix.LiveView
  def handle_info({:flash, {type, message}}, socket) do
    {:noreply, put_flash(socket, type, message)}
  end

  # Private helper functions
  defp update_custom_input_modes(socket, params) do
    Enum.reduce(params, socket, fn {key, value}, acc ->
      field = field_key_to_atom(key)
      if field, do: try_update_mode(acc, field, value, params), else: acc
    end)
  end

  defp field_key_to_atom("buffer_minutes"), do: :buffer_minutes
  defp field_key_to_atom("advance_booking_days"), do: :advance_booking_days
  defp field_key_to_atom("min_advance_hours"), do: :min_advance_hours
  defp field_key_to_atom(_arg), do: nil

  defp try_update_mode(socket, field, value_str, params) when is_binary(value_str) do
    case Integer.parse(value_str) do
      {int_value, _value} ->
        CustomInputModeHelper.toggle_custom_mode(socket, field, params, int_value)

      _other ->
        socket
    end
  end

  defp try_update_mode(socket, _field, _value, _params) do
    socket
  end
end
