defmodule TymeslotWeb.Components.Icons.ProviderIcon do
  @moduledoc """
  Unified provider icon component for both calendar and video providers.

  Renders logos for all supported providers in different sizes by referencing external SVG files.
  Used across dashboard components for consistent branding.
  """
  use Phoenix.Component

  @doc """
  Renders a provider icon for both calendar and video providers.

  Supports different sizes (compact, medium, large) and all providers:
  - Video: mirotalk, google_meet, teams, custom, in_person, local, none
  - Calendar: google, google_calendar, outlook, outlook_calendar, nextcloud, nextcloud_calendar, caldav

  ## Examples

      <.provider_icon provider="google" type="calendar" size="large" />
      <.provider_icon provider="mirotalk" type="video" size="compact" />
      <.provider_icon provider="google_meet" size="large" />
  """
  attr :provider, :string, required: true
  attr :type, :string, default: nil, values: ["calendar", "video", nil]
  attr :size, :string, default: "large", values: ["compact", "medium", "large"]
  attr :class, :string, default: ""
  attr :icon_class, :string, default: ""

  @spec provider_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def provider_icon(assigns) do
    icon_path = build_icon_path(assigns.provider, assigns.type, assigns.size)
    assigns = assign(assigns, :icon_path, icon_path)

    ~H"""
    <img src={@icon_path} class={build_icon_classes(@size, @class)} alt={"#{@provider} icon"} />
    """
  end

  defp build_icon_path(provider, type, size) do
    # Determine the type based on provider if not explicitly set
    provider_type = type || determine_provider_type(provider)

    # Ensure we have all required parameters
    if provider && provider_type && size do
      # Build the path to the PNG file
      "/icons/providers/#{provider_type}/#{size}/#{provider}.png"
    else
      # Return nil if any parameter is missing
      nil
    end
  end

  defp determine_provider_type(provider) do
    case provider do
      p when p in ["mirotalk", "google_meet", "teams", "custom", "in_person", "local", "none"] ->
        "video"

      p
      when p in [
             "google",
             "google_calendar",
             "outlook",
             "outlook_calendar",
             "nextcloud",
             "nextcloud_calendar",
             "caldav",
             "radicale"
           ] ->
        "calendar"

      # default to calendar
      _ ->
        "calendar"
    end
  end

  defp build_icon_classes(size, additional_class) do
    base_classes =
      case size do
        "large" -> "w-8 h-8"
        "medium" -> "w-7 h-7"
        "compact" -> "w-6 h-6"
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
