defmodule TymeslotWeb.OnboardingLive do
  use TymeslotWeb, :live_view

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias TymeslotWeb.CustomInputModeHelper
  alias TymeslotWeb.OnboardingLive.BasicSettingsShared
  alias TymeslotWeb.OnboardingLive.CalendarHandlers
  alias TymeslotWeb.OnboardingLive.ConnectCalendarStep
  alias TymeslotWeb.OnboardingLive.NavigationHandlers
  alias TymeslotWeb.OnboardingLive.OnboardingLayout
  alias TymeslotWeb.OnboardingLive.PreferencesStep
  alias TymeslotWeb.OnboardingLive.ProfileHandlers
  alias TymeslotWeb.OnboardingLive.ProfileStep
  alias TymeslotWeb.OnboardingLive.ReadyStep
  alias TymeslotWeb.OnboardingLive.SchedulingHandlers
  alias TymeslotWeb.OnboardingLive.SkipConfirmationModal
  alias TymeslotWeb.OnboardingLive.StepConfig
  alias TymeslotWeb.OnboardingLive.TimezoneHandlers
  alias TymeslotWeb.OnboardingLive.WelcomeStep

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    is_debug = socket.assigns.live_action in [:debug_welcome, :debug_step]

    if user.onboarding_completed_at && !is_debug do
      {:ok,
       socket
       |> put_flash(:info, "You have already completed onboarding.")
       |> redirect(to: ~p"/dashboard")}
    else
      {:ok, initialize_onboarding(socket, user)}
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
      redirect_path =
        if socket.assigns.live_action in [:debug_welcome, :debug_step] do
          ~p"/debug/onboarding"
        else
          ~p"/onboarding"
        end

      {:noreply, redirect(socket, to: redirect_path)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :current_step, :welcome)}
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <OnboardingLayout.onboarding_layout
      current_step={@current_step}
      steps={@steps}
      show_skip_modal={@show_skip_modal}
    >
      <%= case @current_step do %>
        <% :welcome -> %>
          <WelcomeStep.welcome_step />
        <% :profile -> %>
          <ProfileStep.profile_step
            profile={@profile}
            form_data={@form_data}
            timezone_options={@timezone_options}
            timezone_dropdown_open={@timezone_dropdown_open}
            timezone_search={@timezone_search}
            form_errors={@form_errors}
          />
        <% :connect_calendar -> %>
          <ConnectCalendarStep.connect_calendar_step
            calendar_state={@calendar_state}
            connected_calendars={@connected_calendars}
            caldav_form_data={@caldav_form_data}
            caldav_form_errors={@caldav_form_errors}
          />
        <% :buffer_time -> %>
          <PreferencesStep.buffer_time_step
            profile={@profile}
            form_errors={@form_errors}
            custom_input_mode={@custom_input_mode}
          />
        <% :booking_window -> %>
          <PreferencesStep.booking_window_step
            profile={@profile}
            form_errors={@form_errors}
            custom_input_mode={@custom_input_mode}
          />
        <% :minimum_notice -> %>
          <PreferencesStep.minimum_notice_step
            profile={@profile}
            form_errors={@form_errors}
            custom_input_mode={@custom_input_mode}
          />
        <% :ready -> %>
          <ReadyStep.ready_step booking_url={@booking_url} />
      <% end %>
    </OnboardingLayout.onboarding_layout>

    <%!-- Skip confirmation modal --%>
    <SkipConfirmationModal.skip_confirmation_modal show={@show_skip_modal} />
    """
  end

  # ------------------------------------------------------------------
  # Event handlers — Navigation
  # ------------------------------------------------------------------

  @impl Phoenix.LiveView
  def handle_event("next_step", _params, socket) do
    NavigationHandlers.handle_next_step(socket)
  end

  def handle_event("previous_step", _params, socket) do
    NavigationHandlers.handle_previous_step(socket)
  end

  def handle_event("skip_step", _params, socket) do
    NavigationHandlers.handle_skip_step(socket)
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

  # ------------------------------------------------------------------
  # Event handlers — Profile (basic settings)
  # ------------------------------------------------------------------

  def handle_event("validate_basic_settings", params, socket) do
    ProfileHandlers.handle_validate_basic_settings(params, socket)
  end

  def handle_event("update_basic_settings", _params, socket) do
    NavigationHandlers.handle_next_step(socket)
  end

  # ------------------------------------------------------------------
  # Event handlers — Calendar connection
  # ------------------------------------------------------------------

  def handle_event("connect_google_calendar", _params, socket) do
    CalendarHandlers.handle_connect_google(socket)
  end

  def handle_event("connect_outlook_calendar", _params, socket) do
    CalendarHandlers.handle_connect_outlook(socket)
  end

  def handle_event("show_caldav_form", _params, socket) do
    CalendarHandlers.handle_show_caldav_form(socket)
  end

  def handle_event("cancel_caldav", _params, socket) do
    CalendarHandlers.handle_cancel_caldav(socket)
  end

  def handle_event("validate_caldav", params, socket) do
    CalendarHandlers.handle_validate_caldav(params, socket)
  end

  def handle_event("discover_caldav_calendars", params, socket) do
    CalendarHandlers.handle_discover_caldav(params, socket)
  end

  def handle_event("add_another_calendar", _params, socket) do
    CalendarHandlers.handle_add_another(socket)
  end

  # ------------------------------------------------------------------
  # Event handlers — Scheduling preferences
  # ------------------------------------------------------------------

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

  def handle_event("focus_custom_input", %{"setting" => setting}, socket) do
    with %{} = config <- StepConfig.custom_input_config()[setting],
         %{} = profile <- socket.assigns[:profile] do
      current = Map.get(profile, config.field) || config.constraints.default_custom

      custom_value =
        if current in config.presets,
          do: config.constraints.default_custom,
          else: current

      params = %{setting => to_string(custom_value)}

      {:noreply, updated_socket} =
        SchedulingHandlers.handle_update_scheduling_preferences(params, socket)

      if Map.get(updated_socket.assigns, :form_errors, %{}) == %{} do
        {:noreply, CustomInputModeHelper.enable_custom_mode(updated_socket, config.field)}
      else
        {:noreply, updated_socket}
      end
    else
      _other -> {:noreply, socket}
    end
  end

  # ------------------------------------------------------------------
  # Event handlers — Timezone
  # ------------------------------------------------------------------

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

  # ------------------------------------------------------------------
  # handle_info
  # ------------------------------------------------------------------

  @impl Phoenix.LiveView
  def handle_info({:flash, {type, message}}, socket) do
    {:noreply, put_flash(socket, type, message)}
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp initialize_onboarding(socket, user) do
    profile = load_profile(socket, user)

    connected_calendars =
      if connected?(socket), do: Calendar.list_integrations(user.id), else: []

    socket
    |> assign(:profile, profile)
    |> then(fn s ->
      if profile,
        do: assign(s, :form_data, BasicSettingsShared.build_form_data(s)),
        else: assign(s, :form_data, %{})
    end)
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
    |> assign(:calendar_state, :selecting)
    |> assign(:connected_calendars, connected_calendars)
    |> assign(:caldav_form_data, %{})
    |> assign(:caldav_form_errors, %{})
    |> assign(:booking_url, build_booking_url(profile))
  end

  defp load_profile(socket, user) do
    if connected?(socket) do
      {:ok, loaded} = Onboarding.get_or_create_profile(user.id)
      detected_timezone = get_connect_params(socket)["timezone"]
      prefilled_profile = Profiles.prefill_timezone(loaded, detected_timezone)

      if prefilled_profile.timezone != loaded.timezone do
        case Profiles.update_timezone(loaded, prefilled_profile.timezone) do
          {:ok, updated} -> updated
          {:error, _reason} -> prefilled_profile
        end
      else
        loaded
      end
    else
      nil
    end
  end

  defp build_booking_url(nil), do: ""

  defp build_booking_url(profile) do
    base = Policy.app_url()
    username = profile.username || ""
    "#{base}/#{username}"
  end

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
