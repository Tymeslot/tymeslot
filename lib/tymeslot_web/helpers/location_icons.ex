defmodule TymeslotWeb.Helpers.LocationIcons do
  @moduledoc """
  The icon each location kind is drawn with, wherever a location appears:
  the host's location list and editor in the dashboard, and the booker's
  picker on the booking page. One table, so the host and the booker always
  see the same glyph for the same kind of place.
  """

  @icons %{
    "in_person" => "hero-building-office",
    "video" => "hero-video-camera",
    "phone" => "hero-phone"
  }

  @fallback "hero-map-pin"

  @doc "The `hero-*` icon name for a location kind; custom and unknown kinds get a map pin."
  @spec icon(String.t() | nil) :: String.t()
  def icon(kind), do: Map.get(@icons, kind, @fallback)
end
