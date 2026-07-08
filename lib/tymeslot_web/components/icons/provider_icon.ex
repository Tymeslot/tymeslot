defmodule TymeslotWeb.Components.Icons.ProviderIcon do
  @moduledoc """
  Unified provider icon component for both calendar and video providers.

  Renders logos for all supported providers in different sizes by referencing external SVG files.
  Used across dashboard components for consistent branding.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig

  @video_meta_providers ~w(in_person local none)
  @oauth_only_providers ~w(github oauth)
  @calendar_providers ~w(
    google_calendar outlook outlook_calendar nextcloud nextcloud_calendar
    caldav radicale zimbra mailbox_org apple baikal
  )

  @doc """
  Renders a provider icon for calendar, video, and OAuth providers.

  Supports different sizes (compact, medium, large) and all providers:
  - Video: mirotalk, google_meet, teams, zoom, custom, in_person, local, none
  - Calendar: google, google_calendar, outlook, outlook_calendar, nextcloud, nextcloud_calendar, caldav, radicale, zimbra, mailbox_org
  - OAuth: google, github

  ## Examples

      <.provider_icon provider="google" type="calendar" size="large" />
      <.provider_icon provider="mirotalk" type="video" size="compact" />
      <.provider_icon provider="google_meet" size="large" />
      <.provider_icon provider="google" type="oauth" size="medium" />
  """
  attr :provider, :string, required: true
  attr :type, :string, default: nil, values: ["calendar", "video", "oauth", nil]
  attr :size, :string, default: "large", values: ["compact", "medium", "large", "mini"]
  attr :class, :string, default: ""
  attr :icon_class, :string, default: ""

  @spec provider_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def provider_icon(assigns) do
    icon_path = build_icon_path(assigns.provider, assigns.type, assigns.size)
    assigns = assign(assigns, :icon_path, icon_path)

    ~H"""
    <img
      src={@icon_path}
      class={build_icon_classes(@size, @class)}
      alt={dgettext("dashboard_common", "%{provider} icon", provider: @provider)}
    />
    """
  end

  # The in-memory debug calendar (dev only) has no branded logo. Point at a
  # bundled demo SVG — which scales to any size — so it renders an icon instead
  # of a broken `<img>` for the missing `debug.png`.
  defp build_icon_path("debug", _type, _size), do: "/icons/providers/calendar/debug.svg"

  # Apple ships a single monochrome glyph (the Apple logo) rather than the
  # multi-size branded PNGs the other providers use. Point at the bundled SVG —
  # which scales to any size — instead of a non-existent apple.png.
  defp build_icon_path("apple", _type, _size), do: "/icons/providers/calendar/apple.svg"

  defp build_icon_path(provider, type, size) do
    # Determine the type based on provider if not explicitly set
    provider_type = type || determine_provider_type(provider)

    # Map mini size to compact for the icon file path if needed
    # (Assuming we use compact icons for mini size)
    actual_size = if size == "mini", do: "compact", else: size

    # Ensure we have all required parameters
    if provider && provider_type && actual_size do
      # Build the path to the PNG file
      filename = normalize_provider_filename(provider)
      "/icons/providers/#{provider_type}/#{actual_size}/#{filename}.png"
    else
      # Return nil if any parameter is missing
      nil
    end
  end

  # Some providers are referenced by aliases (e.g. "google_calendar") but their
  # icon files are stored under the shorter base name ("google").
  defp normalize_provider_filename("google_calendar"), do: "google"
  defp normalize_provider_filename("outlook_calendar"), do: "outlook"
  defp normalize_provider_filename("nextcloud_calendar"), do: "nextcloud"
  defp normalize_provider_filename(provider), do: provider

  defp determine_provider_type(provider) do
    cond do
      video_provider?(provider) -> "video"
      provider in @oauth_only_providers -> "oauth"
      # Note: OAuth providers share names with calendar providers.
      # Caller should explicitly specify type="oauth" when using OAuth context.
      provider == "google" -> "calendar"
      provider in @calendar_providers -> "calendar"
      true -> "calendar"
    end
  end

  defp video_provider?(provider) when is_binary(provider) do
    provider in @video_meta_providers or
      match?({:ok, _atom}, VideoProviderConfig.parse_known(provider))
  end

  defp video_provider?(_other), do: false

  defp build_icon_classes(size, additional_class) do
    base_classes =
      case size do
        "large" -> "w-8 h-8"
        "medium" -> "w-7 h-7"
        "compact" -> "w-6 h-6"
        "mini" -> "w-4 h-4"
      end

    "#{base_classes} #{additional_class}"
  end

  @doc """
  Legacy video provider logo function for backwards compatibility.
  Redirects to the unified provider_icon component.
  """
  attr :provider, :string, required: true
  attr :size, :string, default: "large", values: ["compact", "large"]
  attr :class, :string, default: ""

  @spec video_provider_logo(map()) :: Phoenix.LiveView.Rendered.t()
  def video_provider_logo(assigns) do
    assigns = assign(assigns, :type, "video")

    ~H"""
    <.provider_icon provider={@provider} size={@size} class={@class} />
    """
  end
end
