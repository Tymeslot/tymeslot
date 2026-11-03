defmodule TymeslotWeb.OnboardingLive.Initializer do
  @moduledoc """
  Mount-time setup for the onboarding LiveView.

  Loads (or creates) the profile, seeds video backgrounds when a calendar is
  already connected, resolves the initial theme state, and assigns the full
  initial socket state including the avatar upload. Keeps the LiveView's
  `mount/3` a one-liner that delegates here.

  The disconnected (first) render gets the same state from reads alone: the
  profile if it exists, its form data, theme, connected calendars and
  whether the page is live, so the first paint is the host's own page and
  nothing swaps or jumps when the socket connects. Only the connected mount
  writes (creating the profile, its timezone, the video backgrounds), and
  only the connected mount starts reading the host's week (`WeekReveal`).
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
  alias TymeslotWeb.OnboardingLive.WeekReveal
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
    connected_calendars = Calendar.list_integrations(user.id)

    # Seed every theme that offers video backgrounds (Quill and Rhythm) with a
    # random one the moment a calendar is connected (the point the theme step
    # unlocks), before reading the customization below so the assigned state
    # reflects it. A write, so the connected mount does it.
    if connected?(socket), do: ThemeHandlers.seed_video_backgrounds(profile, connected_calendars)

    {customization, onboarding_choices} = ThemeHandlers.initial_theme_state(profile)

    socket
    |> Component.assign(:profile, profile)
    |> BasicSettingsShared.assign_form_data()
    |> Component.assign(initial_ui_state())
    |> ModalHook.mount_modal(theme_preview: false, stage_preview: false)
    |> Component.assign(
      connected_calendars: connected_calendars,
      google_signup_email: Auth.google_signup_login_hint(user),
      booking_url: build_booking_url(profile),
      theme_customization: customization,
      onboarding_choices: onboarding_choices
    )
    |> assign_booking_page_live(profile)
    |> assign_initial_week()
    |> allow_avatar_upload()
  end

  # Whether the page accepts visitors decides where a host resumes, so it is
  # known from the first render. Before a profile exists it stays unknown.
  defp assign_booking_page_live(socket, nil), do: socket

  defp assign_booking_page_live(socket, _profile),
    do: NavigationHandlers.assign_booking_page_live(socket)

  # A host with a bookable calendar sees their week loading from the first
  # paint, and the connected mount reads it (`WeekReveal`).
  defp assign_initial_week(socket) do
    socket
    |> Component.assign(:stage_week, WeekReveal.initial_week(socket.assigns.booking_page_live))
    |> WeekReveal.maybe_start()
  end

  # The wizard's state before the organiser has done anything: the first
  # step, every modal and dropdown closed, and every form empty.
  defp initial_ui_state do
    [
      current_step: :profile,
      # Unknown until the connected render checks the calendars.
      booking_page_live: nil,
      returning_to_share: false,
      # The booking page's coming week, drawn on the stage once a calendar
      # is connected (`WeekReveal`).
      stage_week: WeekReveal.initial_week(false),
      # Bumped whenever a new week arrives, so the stage reveals its times
      # once on that render and never again on a later one.
      reveal_key: 0,
      # What the layout's live region announces about the stage (see
      # `OnboardingLayout`); a step that changes the stage writes a sentence
      # here.
      stage_announcement: "",
      # Set by the LiveView after the host's first action (see
      # `OnboardingLayout`), so the page load never moves the focus.
      focus_heading: false,
      timezone_options: Timezones.all_options(),
      # The timezone shows as one line until the host asks to change it.
      timezone_editing: false,
      # Set when the picker closes, so the Change button it gave way to takes
      # the focus back.
      timezone_focus_change: false,
      timezone_dropdown_open: false,
      timezone_search: "",
      page_title: dgettext("onboarding_wizard", "Set up your page"),
      form_errors: %{},
      calendar_state: :selecting,
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

  # The disconnected render only reads: a host on their first visit has no
  # profile yet, and the connected mount creates it.
  defp load_profile(socket, user) do
    if connected?(socket) do
      with {:ok, loaded} <- Onboarding.get_or_create_profile(user.id) do
        {:ok, profile} = Profiles.ensure_timezone(loaded, get_connect_params(socket)["timezone"])
        profile
      end
    else
      Profiles.get_profile(user.id)
    end
  end

  defp build_booking_url(nil), do: ""
  defp build_booking_url(profile), do: UrlBuilder.booking_url(profile.username)
end
