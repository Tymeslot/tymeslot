defmodule TymeslotWeb.OnboardingLive.Initializer do
  @moduledoc """
  Mount-time setup for the onboarding LiveView.

  Loads (or creates) the profile, seeds video backgrounds when a calendar is
  already connected, resolves the initial theme state, and assigns the full
  initial socket state including the avatar upload. Keeps the LiveView's
  `mount/3` a one-liner that delegates here.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.LiveView, only: [connected?: 1, get_connect_params: 1, allow_upload: 3]

  alias Phoenix.Component
  alias Tymeslot.Auth
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.Avatars
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.CustomInputModeHelper
  alias TymeslotWeb.OnboardingLive.AvatarHandlers
  alias TymeslotWeb.OnboardingLive.BasicSettingsShared
  alias TymeslotWeb.OnboardingLive.StepConfig
  alias TymeslotWeb.OnboardingLive.ThemeHandlers
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @doc """
  Builds the initial socket state for a freshly mounted onboarding session.
  """
  @spec initialize(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def initialize(socket, user) do
    profile = load_profile(socket, user)

    connected_calendars =
      if connected?(socket), do: Calendar.list_integrations(user.id), else: []

    # Seed both themes with a random video background the moment a calendar is
    # connected (the point the theme step unlocks), before reading the
    # customization below so the assigned state reflects it.
    ThemeHandlers.seed_video_backgrounds(profile, connected_calendars)

    {customization, color_scheme} = ThemeHandlers.initial_theme_state(profile)

    socket
    |> Component.assign(
      profile: profile,
      availability_schedule: load_default_schedule(profile),
      time_format: load_time_format(socket, user)
    )
    |> assign_form_data(profile)
    |> Component.assign(initial_ui_state())
    |> Component.assign(
      steps: StepConfig.steps(connected_calendars != []),
      connected_calendars: connected_calendars,
      google_signup_email: Auth.google_signup_login_hint(user),
      booking_url: build_booking_url(profile),
      theme_customization: customization,
      color_scheme: color_scheme
    )
    |> allow_avatar_upload()
  end

  # The wizard's state before the organiser has done anything: the first
  # step, every modal and dropdown closed, and every form empty.
  defp initial_ui_state do
    [
      current_step: :welcome,
      step_data: %{},
      show_skip_modal: false,
      show_skip_calendar_modal: false,
      show_theme_preview: false,
      theme_preview_url: nil,
      timezone_options: Timezones.all_options(),
      timezone_dropdown_open: false,
      timezone_search: "",
      page_title: dgettext("onboarding_wizard", "Welcome"),
      form_errors: %{},
      rejected_inputs: %{},
      custom_input_mode: CustomInputModeHelper.default_custom_mode(),
      calendar_state: :selecting,
      calendar_choice: nil,
      caldav_form_data: %{},
      caldav_form_errors: %{},
      caldav_discovering: false,
      theme_options: ThemeInfo.theme_options()
    ]
  end

  defp allow_avatar_upload(socket) do
    allow_upload(socket, :avatar,
      accept: Avatars.accepted_extensions(),
      max_entries: 1,
      max_file_size: Avatars.max_file_size(),
      auto_upload: true,
      progress: &AvatarHandlers.handle_progress/3
    )
  end

  defp assign_form_data(socket, nil), do: Component.assign(socket, :form_data, %{})

  defp assign_form_data(socket, _profile) do
    Component.assign(socket, :form_data, BasicSettingsShared.build_form_data(socket))
  end

  # The clock the organiser reads times in: their stored choice, or the one
  # their language implies. The static render skips the query.
  defp load_time_format(socket, user) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    CalendarGrid.get_user_time_format(if(connected?(socket), do: user.id), locale)
  end

  defp load_profile(socket, user) do
    if connected?(socket) do
      {:ok, loaded} = Onboarding.get_or_create_profile(user.id)
      {:ok, profile} = Profiles.ensure_timezone(loaded, get_connect_params(socket)["timezone"])
      profile
    else
      nil
    end
  end

  # The buffers, booking window and minimum notice edited by the preference
  # steps live on the profile's default availability schedule. There is no
  # profile during the disconnected render, so there is no schedule either.
  defp load_default_schedule(nil), do: nil
  defp load_default_schedule(profile), do: Schedules.get_default(profile.id)

  defp build_booking_url(nil), do: ""
  defp build_booking_url(profile), do: UrlBuilder.booking_url(profile.username)
end
