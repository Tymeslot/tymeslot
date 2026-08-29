defmodule TymeslotWeb.OnboardingLive.ThemeHandlers do
  @moduledoc """
  Theme, colour-scheme and booking-page-preview handlers for the onboarding flow.

  Owns the "choose your theme" feature end to end: selecting a booking theme or
  colour scheme, seeding a random video background once a calendar is connected,
  and opening/closing the real full-page preview of the user's own booking page.
  It also exposes the theme-state helpers the mount pipeline needs, so every
  theme concern lives in one place rather than leaking into the LiveView.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations
  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @doc """
  Persists the selected booking theme and refreshes the preview state.
  """
  @spec handle_select_theme(String.t(), LiveView.Socket.t()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_select_theme(theme_id, socket) do
    profile = socket.assigns[:profile]

    if profile && ThemeInfo.valid_theme_id?(theme_id) do
      case Profiles.update_booking_theme(profile, theme_id) do
        {:ok, updated} ->
          {:noreply, assign_theme_state(socket, updated)}

        {:error, _reason} ->
          {:noreply,
           LiveView.put_flash(
             socket,
             :error,
             dgettext("onboarding_wizard", "Could not update theme. Please try again.")
           )}
      end
    else
      {:noreply, socket}
    end
  end

  @doc """
  Applies a colour scheme to the current theme, preserving its other
  customisation (e.g. the seeded video background).
  """
  @spec handle_select_color_scheme(String.t(), LiveView.Socket.t()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_select_color_scheme(scheme_id, socket) do
    profile = socket.assigns[:profile]

    if profile do
      case ThemeCustomizations.apply_color_scheme_change(
             profile.id,
             profile.booking_theme,
             socket.assigns.theme_customization,
             scheme_id
           ) do
        {:ok, customization} ->
          {:noreply,
           socket
           |> Component.assign(:theme_customization, customization)
           |> Component.assign(:color_scheme, customization.color_scheme)}

        {:error, _reason} ->
          {:noreply,
           LiveView.put_flash(
             socket,
             :error,
             dgettext(
               "onboarding_wizard",
               "Could not update the colour scheme. Please try again."
             )
           )}
      end
    else
      {:noreply, socket}
    end
  end

  @doc """
  Opens the full-page preview of the user's own booking page, lazily assigning
  a default username first if the user left theirs blank.
  """
  @spec handle_preview_booking_page(LiveView.Socket.t()) :: {:noreply, LiveView.Socket.t()}
  def handle_preview_booking_page(socket) do
    case ensure_preview_username(socket) do
      {:ok, socket, username} ->
        {:noreply,
         socket
         |> Component.assign(
           :theme_preview_url,
           # Standalone, not `embed=1`: `preview=true` pins CSP
           # `frame-ancestors 'self'` so it frames same-origin, and standalone
           # keeps the video background and fills the frame to full height, so
           # the modal shows the page exactly as invitees see it rather than a
           # chrome-stripped, video-less card.
           PreviewMode.owner_url(username, socket.assigns.profile.user_id)
         )
         |> Component.assign(:show_theme_preview, true)}

      {:error, socket} ->
        {:noreply,
         LiveView.put_flash(
           socket,
           :error,
           dgettext("onboarding_wizard", "Could not open the preview. Please try again.")
         )}
    end
  end

  @doc """
  Closes the preview and drops the URL so the iframe is torn down. Reopening
  then loads a fresh frame reflecting the latest persisted theme/colour, and
  stops the embedded page running in the background while hidden.
  """
  @spec handle_close_theme_preview(LiveView.Socket.t()) :: {:noreply, LiveView.Socket.t()}
  def handle_close_theme_preview(socket) do
    {:noreply,
     socket
     |> Component.assign(:show_theme_preview, false)
     |> Component.assign(:theme_preview_url, nil)}
  end

  @doc """
  Resolves the initial `{customization, color_scheme}` for a profile (or the
  neutral default before a profile exists) for the mount pipeline.
  """
  @spec initial_theme_state(map() | nil) :: {map() | nil, String.t()}
  def initial_theme_state(nil), do: {nil, "default"}

  def initial_theme_state(profile) do
    %{customization: customization} =
      ThemeCustomizations.initialize_customization(profile.id, profile.booking_theme)

    {customization, customization.color_scheme}
  end

  @doc """
  Seeds a random video background across every onboarding booking theme once a
  calendar is connected, so the preview shows motion out of the box. No-op
  without a profile or a connected calendar.
  """
  @spec seed_video_backgrounds(map() | nil, list()) :: :ok
  def seed_video_backgrounds(nil, _connected_calendars), do: :ok
  def seed_video_backgrounds(_profile, []), do: :ok

  def seed_video_backgrounds(profile, _connected_calendars) do
    Onboarding.ensure_preview_video_backgrounds(profile, theme_ids())
  end

  defp assign_theme_state(socket, profile) do
    {customization, color_scheme} = initial_theme_state(profile)

    socket
    |> Component.assign(:profile, profile)
    |> Component.assign(:theme_customization, customization)
    |> Component.assign(:color_scheme, color_scheme)
  end

  # Booking-theme ids offered in onboarding, derived from the theme registry.
  defp theme_ids do
    Enum.map(ThemeInfo.theme_options(), fn {_name, id} -> id end)
  end

  # The preview needs a resolvable username. Most users set one on the profile
  # step; for anyone who left it blank we lazily assign the system default
  # (same one onboarding completion would assign) so the page resolves.
  defp ensure_preview_username(socket) do
    profile = socket.assigns.profile

    case profile.username do
      username when is_binary(username) and username != "" ->
        {:ok, socket, username}

      _blank ->
        default = Profiles.generate_default_username(profile.user_id)

        case Profiles.assign_default_username(profile, default) do
          {:ok, updated} -> {:ok, Component.assign(socket, :profile, updated), updated.username}
          {:error, _reason} -> {:error, socket}
        end
    end
  end
end
