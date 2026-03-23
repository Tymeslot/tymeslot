defmodule Tymeslot.Emails.Shared.AvatarHelper do
  @moduledoc """
  Helper functions for generating avatar URLs in email templates.
  """

  alias Tymeslot.Emails.Shared.SharedHelpers

  @doc """
  Generates an avatar URL for an organizer.
  Uses the provided avatar URL if available, otherwise generates a default SVG avatar based on the organizer name.
  """
  @spec generate_avatar_url(map() | keyword()) :: String.t()
  def generate_avatar_url(appointment_details) do
    details =
      if is_list(appointment_details), do: Map.new(appointment_details), else: appointment_details

    case Map.get(details, :organizer_avatar_url) do
      nil ->
        name = Map.get(details, :organizer_name) || "User"
        generate_default_avatar(name)

      url when is_binary(url) ->
        url

      _other ->
        name = Map.get(details, :organizer_name) || "User"
        generate_default_avatar(name)
    end
  end

  @doc """
  Generates a default SVG-based avatar data URI.
  """
  @spec generate_default_avatar(String.t()) :: String.t()
  def generate_default_avatar(organizer_name) do
    name = organizer_name || "User"

    initials =
      name
      |> String.split()
      |> Enum.map_join("", &String.first/1)
      |> String.upcase()
      |> SharedHelpers.sanitize_for_email()

    svg = """
    <svg width="50" height="50" viewBox="0 0 50 50" xmlns="http://www.w3.org/2000/svg">
      <circle cx="25" cy="25" r="25" fill="#14b8a6"/>
      <text x="25" y="30" text-anchor="middle" font-family="sans-serif" font-size="20" font-weight="600" fill="white">#{initials}</text>
    </svg>
    """

    encoded = Base.encode64(svg)
    "data:image/svg+xml;base64,#{encoded}"
  end
end
