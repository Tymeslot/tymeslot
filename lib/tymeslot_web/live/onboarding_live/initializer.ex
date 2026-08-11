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
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.Avatars
  alias Tymeslot.Timezones
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
    |> Component.assign(:profile, profile)
    |> Component.assign(:availability_schedule, load_default_schedule(profile))
    |> assign_form_data(profile)
    |> Component.assign(:current_step, :welcome)
    |> Component.assign(:step_data, %{})
    |> Component.assign(:show_skip_modal, false)
    |> Component.assign(:show_skip_calendar_modal, false)
    |> Component.assign(:show_theme_preview, false)
    |> Component.assign(:theme_preview_url, nil)
    |> Component.assign(:steps, StepConfig.steps(connected_calendars != []))
    |> Component.assign(:timezone_options, Timezones.all_options())
    |> Component.assign(:timezone_dropdown_open, false)
    |> Component.assign(:timezone_search, "")
    |> Component.assign(:page_title, dgettext("onboarding_wizard", "Welcome"))
    |> Component.assign(:form_errors, %{})
    |> Component.assign(:custom_input_mode, CustomInputModeHelper.default_custom_mode())
    |> Component.assign(:calendar_state, :selecting)
    |> Component.assign(:calendar_choice, nil)
    |> Component.assign(:connected_calendars, connected_calendars)
    |> Component.assign(:google_signup_email, Auth.google_signup_login_hint(user))
    |> Component.assign(:caldav_form_data, %{})
    |> Component.assign(:caldav_form_errors, %{})
    |> Component.assign(:caldav_discovering, false)
    |> Component.assign(:booking_url, build_booking_url(profile))
    |> Component.assign(:theme_options, ThemeInfo.theme_options())
    |> Component.assign(:theme_customization, customization)
    |> Component.assign(:color_scheme, color_scheme)
    |> allow_upload(:avatar,
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

  # The buffer, booking window and minimum notice edited by the preference
  # steps live on the profile's default availability schedule. There is no
  # profile during the disconnected render, so there is no schedule either.
  defp load_default_schedule(nil), do: nil
  defp load_default_schedule(profile), do: Schedules.get_default(profile.id)

  defp build_booking_url(nil), do: ""

  defp build_booking_url(profile) do
    "#{Policy.app_url()}/#{profile.username || ""}"
  end
end
