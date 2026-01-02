defmodule Tymeslot.Utils.AvatarUtils do
  @moduledoc """
  Utilities for generating fallback avatars.
  """

  @doc """
  Generates a fallback SVG avatar based on user's initials and a consistent color.
  """
  @spec generate_fallback_svg(map() | nil, non_neg_integer()) :: String.t()
  def generate_fallback_svg(profile, size \\ 300)
  def generate_fallback_svg(nil, size), do: generate_generic_fallback_svg(size)

  def generate_fallback_svg(profile, size) do
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
            fill="white">#{initials}</text>
    </svg>
    """
  rescue
    # Fallback to a simple SVG if anything goes wrong
    _ ->
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

  @doc """
  Gets initials from a profile.
  """
  @spec get_initials(map() | nil) :: String.t()
  def get_initials(nil), do: "U"

  def get_initials(profile) do
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
    # Handle any potential errors gracefully
    _ -> "U"
  end

  @doc """
  Gets a consistent color scheme based on the profile ID.
  """
  @spec get_consistent_color(map() | nil) :: %{start: String.t(), end: String.t()}
  def get_consistent_color(nil), do: %{start: "#667eea", end: "#764ba2"}

  def get_consistent_color(profile) do
    # Use profile ID to generate consistent colors
    profile_id = Map.get(profile, :id, 0)
    hash = :erlang.phash2(profile_id, 1000)

    # Predefined color schemes that work well for avatars
    color_schemes = [
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

    Enum.at(color_schemes, rem(hash, length(color_schemes)))
  end

  @doc """
  Generates a generic fallback SVG avatar for cases where no profile exists.
  """
  @spec generate_generic_fallback_svg(non_neg_integer()) :: String.t()
  def generate_generic_fallback_svg(size \\ 300) do
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

  @doc """
  Generates a generic fallback data URI for cases where no profile exists.
  """
  @spec generate_generic_fallback_data_uri(non_neg_integer()) :: String.t()
  def generate_generic_fallback_data_uri(size \\ 300) do
    svg = generate_generic_fallback_svg(size)
    encoded = Base.encode64(svg)
    "data:image/svg+xml;base64,#{encoded}"
  end
end
