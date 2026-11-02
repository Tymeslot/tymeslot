defmodule TymeslotWeb.OnboardingLive.Initializer do
  @moduledoc """
  Mount-time setup for the onboarding LiveView.

  Loads (or creates) the profile, seeds video backgrounds when a calendar is
  already connected, resolves the initial theme state, and assigns the full
  initial socket state including the avatar upload. Keeps the LiveView's
  `mount/3` a one-liner that delegates here.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb, :verified_routes

  import Phoenix.LiveView,
    only: [connected?: 1, get_connect_params: 1, allow_upload: 3, redirect: 2]

  alias Phoenix.Component
  alias Tymeslot.Auth
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.Avatars
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.OnboardingLive.AvatarHandlers
  alias TymeslotWeb.OnboardingLive.BasicSettingsShared
  alias TymeslotWeb.OnboardingLive.NavigationHandlers
  alias TymeslotWeb.OnboardingLive.ThemeHandlers
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @doc """
  Builds the initial socket state for a freshly mounted onboarding session.
  """
  @spec initialize(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def initialize(socket, user) do
    case load_profile(socket, user) do
      # The account was deleted between sign-in and this mount.
      {:error, :user_not_found} -> redirect(socket, to: ~p"/auth/login")
      profile -> initialize_with_profile(socket, user, profile)
    end
  end

  defp initialize_with_profile(socket, user, profile) do
    connected_calendars =
      if connected?(socket), do: Calendar.list_integrations(user.id), else: []

    # Seed every theme that offers video backgrounds (Quill and Rhythm) with a
    # random one the moment a calendar is connected (the point the theme step
    # unlocks), before reading the customization below so the assigned state
    # reflects it.
    ThemeHandlers.seed_video_backgrounds(profile, connected_calendars)

    {customization, onboarding_choices} = ThemeHandlers.initial_theme_state(profile)

    socket
    |> Component.assign(:profile, profile)
    |> assign_form_data(profile)
    |> Component.assign(initial_ui_state())
    |> ModalHook.mount_modal(theme_preview: false)
    |> Component.assign(
      connected_calendars: connected_calendars,
      google_signup_email: Auth.google_signup_login_hint(user),
      booking_url: build_booking_url(profile),
      theme_customization: customization,
      onboarding_choices: onboarding_choices
    )
    |> assign_booking_page_live(profile)
    |> allow_avatar_upload()
  end

  # Whether the page accepts visitors decides where a host resumes, so it is
  # known from the first connected render. The static render has no profile
  # and leaves it unknown.
  defp assign_booking_page_live(socket, nil), do: socket

  defp assign_booking_page_live(socket, _profile),
    do: NavigationHandlers.assign_booking_page_live(socket)

  # The wizard's state before the organiser has done anything: the first
  # step, every modal and dropdown closed, and every form empty.
  defp initial_ui_state do
    [
      current_step: :profile,
      # Unknown until the connected render checks the calendars.
      booking_page_live: nil,
      returning_to_share: false,
      # The booking page's coming week, drawn on the stage once a calendar
      # is connected.
      stage_week: %{state: :placeholder, preview: nil},
      timezone_options: Timezones.all_options(),
      timezone_dropdown_open: false,
      timezone_search: "",
      page_title: dgettext("onboarding_wizard", "Set up your page"),
      form_errors: %{},
      calendar_state: :selecting,
      calendar_choice: nil,
      caldav_form_data: %{},
      caldav_form_errors: %{},
      caldav_discovering: false,
      theme_options: ThemeInfo.theme_options(),
      theme_picker: :stories
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

  defp load_profile(socket, user) do
    if connected?(socket) do
      with {:ok, loaded} <- Onboarding.get_or_create_profile(user.id) do
        {:ok, profile} = Profiles.ensure_timezone(loaded, get_connect_params(socket)["timezone"])
        profile
      end
    else
      nil
    end
  end

  defp build_booking_url(nil), do: ""
  defp build_booking_url(profile), do: UrlBuilder.booking_url(profile.username)
end
