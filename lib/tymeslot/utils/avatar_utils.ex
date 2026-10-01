defmodule Tymeslot.Utils.AvatarUtils do
  @moduledoc """
  Utilities for generating fallback avatars.
  """

  require Logger

  alias Tymeslot.Utils.Colour

  @spec generate_fallback_svg(map(), non_neg_integer()) :: String.t()
  defp generate_fallback_svg(profile, size) do
    initials = get_initials(profile)
    color = get_consistent_color(profile)
    profile_id = Map.get(profile, :id, "default")

    """
    <svg width="#{size}" height="#{size}" viewBox="0 0 #{size} #{size}" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="grad-#{profile_id}" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" style="stop-color:#{color.start};stop-opacity:1" />
          <stop offset="100%" style="stop-color:#{color.end};stop-opacity:1" />
        </linearGradient>
      </defs>
      <circle cx="#{size / 2}" cy="#{size / 2}" r="#{size / 2}" fill="url(#grad-#{profile_id})" />
      <text x="#{size / 2}" y="#{size / 2 + size / 8}" text-anchor="middle"
            font-family="system-ui, -apple-system, sans-serif"
            font-size="#{size / 3}"
            font-weight="600"
            fill="#{color.ink}">#{initials}</text>
    </svg>
    """
  rescue
    # Fallback to a simple SVG if anything goes wrong
    exception ->
      Logger.warning("Falling back to the generic avatar",
        error: Exception.message(exception)
      )

      """
      <svg width="#{size}" height="#{size}" viewBox="0 0 #{size} #{size}" xmlns="http://www.w3.org/2000/svg">
        <circle cx="#{size / 2}" cy="#{size / 2}" r="#{size / 2}" fill="#667eea" />
        <text x="#{size / 2}" y="#{size / 2 + size / 8}" text-anchor="middle"
              font-family="system-ui, -apple-system, sans-serif"
              font-size="#{size / 3}"
              font-weight="600"
              fill="white">U</text>
      </svg>
      """
  end

  @doc """
  Generates a data URI for the fallback SVG avatar.
  """
  @spec generate_fallback_data_uri(map() | nil, non_neg_integer()) :: String.t()
  def generate_fallback_data_uri(profile, size \\ 300)
  def generate_fallback_data_uri(nil, size), do: generate_generic_fallback_data_uri(size)

  def generate_fallback_data_uri(profile, size) do
    svg = generate_fallback_svg(profile, size)
    encoded = Base.encode64(svg)
    "data:image/svg+xml;base64,#{encoded}"
  end

  @spec get_initials(map()) :: String.t()
  defp get_initials(profile) do
    cond do
      profile.full_name && String.trim(profile.full_name) != "" ->
        profile.full_name
        |> String.trim()
        |> String.split()
        |> Enum.take(2)
        |> Enum.map_join("", &String.first/1)
        |> String.upcase()

      profile.user && profile.user.email ->
        profile.user.email
        |> String.first()
        |> String.upcase()

      true ->
        # Fallback to a generic user icon if no name/email available
        "U"
    end
  rescue
    exception ->
      Logger.warning("Could not derive avatar initials, falling back to \"U\"",
        error: Exception.message(exception)
      )

      "U"
  end

  # Predefined gradients that work well for avatars.
  @gradients [
    # Purple-blue
    %{start: "#667eea", end: "#764ba2"},
    # Pink-red
    %{start: "#f093fb", end: "#f5576c"},
    # Blue-cyan
    %{start: "#4facfe", end: "#00f2fe"},
    # Green-teal
    %{start: "#43e97b", end: "#38f9d7"},
    # Pink-yellow
    %{start: "#fa709a", end: "#fee140"},
    # Light teal-pink
    %{start: "#a8edea", end: "#fed6e3"},
    # Soft pink
    %{start: "#ff9a9e", end: "#fecfef"},
    # Purple-pink
    %{start: "#a18cd1", end: "#fbc2eb"},
    # Peach-pink
    %{start: "#fad0c4", end: "#ffd1ff"},
    # Light orange
    %{start: "#ffecd2", end: "#fcb69f"},
    # Coral-orange
    %{start: "#ff8a80", end: "#ffb74d"},
    # Light blue-green
    %{start: "#8fd3f4", end: "#84fab0"},
    # Purple-yellow
    %{start: "#d299c2", end: "#fef9d7"},
    # Cyan-blue
    %{start: "#89f7fe", end: "#66a6ff"},
    # Yellow-teal
    %{start: "#fdbb2d", end: "#22c1c3"}
  ]

  # The initials are large text, so 3:1 (WCAG 1.4.3) against both stops
  # keeps them legible across the whole circle.
  @minimum_contrast 3.0
  @light_ink "#ffffff"
  @dark_ink "#1f2937"

  @doc """
  The fallback avatar's gradients, each with the ink its initials are drawn
  in: white where it reaches 3:1 against both stops, a dark slate on the
  paler gradients, where white would all but vanish.
  """
  @spec gradients() :: [%{start: String.t(), end: String.t(), ink: String.t()}]
  def gradients, do: Enum.map(@gradients, &Map.put(&1, :ink, ink(&1)))

  defp ink(%{start: start, end: stop}) do
    if Enum.all?([start, stop], &(Colour.contrast_ratio(@light_ink, &1) >= @minimum_contrast)),
      do: @light_ink,
      else: @dark_ink
  end

  @spec get_consistent_color(map()) :: %{start: String.t(), end: String.t(), ink: String.t()}
  defp get_consistent_color(profile) do
    # Use profile ID to generate consistent colors
    profile_id = Map.get(profile, :id, 0)
    hash = :erlang.phash2(profile_id, 1000)
    gradient = Enum.at(@gradients, rem(hash, length(@gradients)))

    Map.put(gradient, :ink, ink(gradient))
  end

  @spec generate_generic_fallback_svg(non_neg_integer()) :: String.t()
  defp generate_generic_fallback_svg(size) do
    """
    <svg width="#{size}" height="#{size}" viewBox="0 0 #{size} #{size}" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="grad-generic" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" style="stop-color:#667eea;stop-opacity:1" />
          <stop offset="100%" style="stop-color:#764ba2;stop-opacity:1" />
        </linearGradient>
      </defs>
      <circle cx="#{size / 2}" cy="#{size / 2}" r="#{size / 2}" fill="url(#grad-generic)" />
      <text x="#{size / 2}" y="#{size / 2 + size / 8}" text-anchor="middle"
            font-family="system-ui, -apple-system, sans-serif"
            font-size="#{size / 3}"
            font-weight="600"
            fill="white">U</text>
    </svg>
    """
  end

  @spec generate_generic_fallback_data_uri(non_neg_integer()) :: String.t()
  defp generate_generic_fallback_data_uri(size) do
    svg = generate_generic_fallback_svg(size)
    encoded = Base.encode64(svg)
    "data:image/svg+xml;base64,#{encoded}"
  end
end
