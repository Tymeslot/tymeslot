defmodule TymeslotWeb.OnboardingLive do
  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Profiles
  alias TymeslotWeb.OnboardingLive.CalendarHandlers
  alias TymeslotWeb.OnboardingLive.ChooseThemeStep
  alias TymeslotWeb.OnboardingLive.ConnectCalendarStep
  alias TymeslotWeb.OnboardingLive.Initializer
  alias TymeslotWeb.OnboardingLive.LivePreview
  alias TymeslotWeb.OnboardingLive.NavigationHandlers
  alias TymeslotWeb.OnboardingLive.OnboardingLayout
  alias TymeslotWeb.OnboardingLive.PreferencesStep
  alias TymeslotWeb.OnboardingLive.ProfileHandlers
  alias TymeslotWeb.OnboardingLive.ProfileStep
  alias TymeslotWeb.OnboardingLive.ReadyStep
  alias TymeslotWeb.OnboardingLive.SchedulingHandlers
  alias TymeslotWeb.OnboardingLive.SkipCalendarModal
  alias TymeslotWeb.OnboardingLive.SkipConfirmationModal
  alias TymeslotWeb.OnboardingLive.StepConfig
  alias TymeslotWeb.OnboardingLive.ThemeHandlers
  alias TymeslotWeb.OnboardingLive.ThemePreviewModal
  alias TymeslotWeb.OnboardingLive.TimezoneHandlers
  alias TymeslotWeb.OnboardingLive.WelcomeStep
  alias TymeslotWeb.Themes.Core.Registry

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    is_debug = socket.assigns.live_action in [:debug_welcome, :debug_step]

    if user.onboarding_completed_at && !is_debug do
      {:ok,
       socket
       |> put_flash(
         :info,
         dgettext("onboarding_wizard", "You have already completed onboarding.")
       )
       |> redirect(to: ~p"/dashboard")}
    else
      {:ok, Initializer.initialize(socket, user)}
    end
  end

  @impl Phoenix.LiveView
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(%{"step" => step}, _uri, socket) do
    if StepConfig.valid_step?(step) do
      step_atom = String.to_existing_atom(step)

      # During the disconnected (static) render the calendar list has not been
      # loaded yet, so `socket.assigns.steps` is always the no-calendar sequence
      # and conditional steps like `:choose_theme` are absent. Redirecting here
      # would wrongly bounce a calendar-connected user who deep-links or refreshes
      # `/onboarding/choose_theme` before the socket connects. Defer the
      # membership check until the connected render, where `mount/3` has run
      # with the real calendar list and `steps` reflects it.
      if !connected?(socket) or step_atom in socket.assigns.steps do
        {:noreply, assign(socket, :current_step, step_atom)}
      else
        {:noreply, redirect(socket, to: onboarding_fallback_path(socket))}
      end
    else
      {:noreply, redirect(socket, to: onboarding_fallback_path(socket))}
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
      next_disabled={
        @current_step == :connect_calendar and is_nil(@calendar_choice) and
          @connected_calendars == []
      }
    >
      <:preview>
        <%!-- The disconnected (dead) render has no profile yet, so it can't
             know the user's theme/colours. Rendering the real preview with
             default colours here would flash the wrong theme the instant the
             socket connects, so show a neutral skeleton until then. --%>
        <LivePreview.preview_skeleton :if={is_nil(@profile)} />
        <LivePreview.live_preview
          :if={@profile}
          current_step={@current_step}
          booking_theme={@profile.booking_theme || Registry.default_theme_id()}
          name={Map.get(@form_data, "full_name", "")}
          username={Map.get(@form_data, "username", "")}
          avatar_url={Profiles.avatar_url(@profile, :thumb)}
          color_scheme={@color_scheme}
          buffer_minutes={policy_value(@availability_schedule, :buffer_minutes)}
          advance_booking_days={policy_value(@availability_schedule, :advance_booking_days)}
          min_advance_hours={policy_value(@availability_schedule, :min_advance_hours)}
          calendar_connected={@connected_calendars != [] or @calendar_choice not in [nil, "skip"]}
          booking_host={booking_host()}
        />
      </:preview>
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
            uploads={@uploads}
            avatar_url={@profile && Profiles.avatar_url(@profile, :thumb)}
          />
        <% :choose_theme -> %>
          <ChooseThemeStep.choose_theme_step
            profile={@profile}
            theme_options={@theme_options}
            color_scheme={@color_scheme}
          />
        <% :connect_calendar -> %>
          <ConnectCalendarStep.connect_calendar_step
            calendar_state={@calendar_state}
            connected_calendars={@connected_calendars}
            calendar_choice={@calendar_choice}
            google_signup_email={@google_signup_email}
            caldav_form_data={@caldav_form_data}
            caldav_form_errors={@caldav_form_errors}
            caldav_discovering={@caldav_discovering}
          />
        <% :buffer_time -> %>
          <PreferencesStep.buffer_time_step
            availability_schedule={@availability_schedule}
            form_errors={@form_errors}
            custom_input_mode={@custom_input_mode}
          />
        <% :booking_window -> %>
          <PreferencesStep.booking_window_step
            availability_schedule={@availability_schedule}
            form_errors={@form_errors}
            custom_input_mode={@custom_input_mode}
          />
        <% :minimum_notice -> %>
          <PreferencesStep.minimum_notice_step
            availability_schedule={@availability_schedule}
            form_errors={@form_errors}
            custom_input_mode={@custom_input_mode}
          />
        <% :ready -> %>
          <ReadyStep.ready_step booking_url={@booking_url} />
      <% end %>
    </OnboardingLayout.onboarding_layout>

    <%!-- Skip confirmation modal --%>
    <SkipConfirmationModal.skip_confirmation_modal show={@show_skip_modal} />

    <%!-- Nudge before continuing without a connected calendar --%>
    <SkipCalendarModal.skip_calendar_modal show={@show_skip_calendar_modal} />

    <%!-- Real booking-page preview --%>
    <ThemePreviewModal.theme_preview_modal
      show={@show_theme_preview}
      url={@theme_preview_url}
    />
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

  def handle_event("show_skip_modal", _params, socket) do
    NavigationHandlers.handle_show_skip_modal(socket)
  end

  def handle_event("hide_skip_modal", _params, socket) do
    NavigationHandlers.handle_hide_skip_modal(socket)
  end

  def handle_event("skip_onboarding", _params, socket) do
    NavigationHandlers.handle_skip_onboarding(socket)
  end

  def handle_event("confirm_skip_calendar", _params, socket) do
    NavigationHandlers.handle_confirm_skip_calendar(socket)
  end

  def handle_event("hide_skip_calendar_modal", _params, socket) do
    NavigationHandlers.handle_hide_skip_calendar_modal(socket)
  end

  # ------------------------------------------------------------------
  # Event handlers — Profile (basic settings + avatar)
  # ------------------------------------------------------------------

  def handle_event("validate_basic_settings", params, socket) do
    ProfileHandlers.handle_validate_basic_settings(params, socket)
  end

  def handle_event("update_basic_settings", _params, socket) do
    NavigationHandlers.handle_next_step(socket)
  end

  def handle_event("validate_avatar", _params, socket) do
    {:noreply, socket}
  end

  # ------------------------------------------------------------------
  # Event handlers — Theme & preview
  # ------------------------------------------------------------------

  def handle_event("select_theme", %{"theme" => theme_id}, socket) do
    ThemeHandlers.handle_select_theme(theme_id, socket)
  end

  def handle_event("select_color_scheme", %{"scheme" => scheme_id}, socket) do
    ThemeHandlers.handle_select_color_scheme(scheme_id, socket)
  end

  def handle_event("preview_booking_page", _params, socket) do
    ThemeHandlers.handle_preview_booking_page(socket)
  end

  def handle_event("close_theme_preview", _params, socket) do
    ThemeHandlers.handle_close_theme_preview(socket)
  end

  # ------------------------------------------------------------------
  # Event handlers — Calendar connection
  # ------------------------------------------------------------------

  def handle_event("select_calendar_option", %{"option" => option}, socket) do
    CalendarHandlers.handle_select_option(option, socket)
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

  # ------------------------------------------------------------------
  # Event handlers — Scheduling preferences
  # ------------------------------------------------------------------

  def handle_event("validate_scheduling_preferences", params, socket) do
    SchedulingHandlers.handle_validate_scheduling_preferences(params, socket)
  end

  def handle_event("update_scheduling_preferences", params, socket) do
    SchedulingHandlers.handle_update_with_custom_modes(params, socket)
  end

  def handle_event("focus_custom_input", %{"setting" => setting}, socket) do
    SchedulingHandlers.handle_focus_custom_input(setting, socket)
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
  # handle_async
  # ------------------------------------------------------------------

  @impl Phoenix.LiveView
  def handle_async(:discover_caldav, result, socket) do
    CalendarHandlers.handle_discover_caldav_result(result, socket)
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

  defp onboarding_fallback_path(socket) do
    if socket.assigns.live_action in [:debug_welcome, :debug_step] do
      ~p"/debug/onboarding"
    else
      ~p"/onboarding"
    end
  end

  defp booking_host do
    String.replace(Policy.app_url(), ~r{^https?://}, "")
  end

  # The booking policy lives on the profile's default availability schedule,
  # which is absent during the disconnected render.
  defp policy_value(nil, _field), do: nil
  defp policy_value(schedule, field), do: Map.get(schedule, field)
end
