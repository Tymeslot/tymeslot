defmodule Tymeslot.Integrations.Calendar.EventColour do
  @moduledoc """
  The single source of truth for Tymeslot's calendar colour palette.

  An event or a calendar integration may carry a stable, provider-independent
  palette **key** (e.g. `"tomato"`) in its `:colour` field. This module maps
  that key to:

    * a Tailwind display class for the calendar grid (`tailwind_class/1`)
    * a Google Calendar `colorId` (`google_color_id/1`)
    * a CSS3 colour name for the CalDAV/iCal `COLOR` property (`css_colour/1`)

  It also owns the rotation an integration falls back to when its owner has
  picked no colour (`rotation_class/1`, `rotation_size/0`), so every
  `bg-calendar-*` class the grid can paint is named in this one module and the
  `@source inline(…)` safelist in `app.css` has a single counterpart in Elixir.

  Mapping to a provider's colour space happens only at the mapper boundary; the
  database stores the palette key. Inbound provider colours (e.g. a raw Google
  `colorId`) may not be palette keys — every lookup falls back gracefully to a
  neutral default rather than raising, so an unrecognised stored value never
  crashes the grid.
  """

  @typedoc "A palette colour key, e.g. `\"tomato\"`."
  @type key :: String.t()

  # Ordered palette. Each entry is `{key, label, tailwind_class}`. The Tailwind
  # classes reuse the existing safelisted `bg-calendar-*` tokens (see
  # `app.css`), so no new CSS is required.
  @palette [
    {"tomato", "Tomato", "bg-calendar-7"},
    {"tangerine", "Tangerine", "bg-calendar-8"},
    {"banana", "Banana", "bg-calendar-1"},
    {"sage", "Sage", "bg-calendar-4"},
    {"peacock", "Peacock", "bg-calendar-5"},
    {"blueberry", "Blueberry", "bg-calendar-2"},
    {"grape", "Grape", "bg-calendar-3"},
    {"graphite", "Graphite", "bg-calendar-fallback"}
  ]

  # Classes the per-integration rotation cycles through when an integration has
  # no colour of its own. Spelled out rather than interpolated so the set is
  # greppable and matches `@source inline("bg-calendar-{1,…,8} …")` in
  # `app.css` one for one. It is not the palette above: the rotation covers
  # every numbered token, while the palette leaves one unused and adds the
  # neutral fallback.
  @rotation_classes [
    "bg-calendar-1",
    "bg-calendar-2",
    "bg-calendar-3",
    "bg-calendar-4",
    "bg-calendar-5",
    "bg-calendar-6",
    "bg-calendar-7",
    "bg-calendar-8"
  ]

  # Palette key → Google Calendar event `colorId` ("1".."11").
  @google_color_ids %{
    "tomato" => "11",
    "tangerine" => "6",
    "banana" => "5",
    "sage" => "2",
    "peacock" => "7",
    "blueberry" => "9",
    "grape" => "3",
    "graphite" => "8"
  }

  # Palette key → CSS3 colour name for the iCal `COLOR` property (RFC 7986).
  @css_colours %{
    "tomato" => "tomato",
    "tangerine" => "darkorange",
    "banana" => "gold",
    "sage" => "yellowgreen",
    "peacock" => "teal",
    "blueberry" => "royalblue",
    "grape" => "darkorchid",
    "graphite" => "slategray"
  }

  # Canonical RGB anchor per palette key — the hex of the CSS3 name each key
  # emits outbound (see @css_colours), so inbound nearest-match and outbound
  # colour agree. Used by nearest_key/1.
  @rgb_anchors %{
    "tomato" => {255, 99, 71},
    "tangerine" => {255, 140, 0},
    "banana" => {255, 215, 0},
    "sage" => {154, 205, 50},
    "peacock" => {0, 128, 128},
    "blueberry" => {65, 105, 225},
    "grape" => {153, 50, 204},
    "graphite" => {112, 128, 144}
  }

  # Full CSS3/CSS Color Module 4 extended colour keyword table (RFC 7986 CalDAV
  # `COLOR` values are typically CSS3 names). Any name outside this table falls
  # back to nil (hex is the common CalDAV form; unsupported names degrade
  # gracefully rather than crashing).
  @css_name_hex %{
    "aliceblue" => "F0F8FF",
    "antiquewhite" => "FAEBD7",
    "aqua" => "00FFFF",
    "aquamarine" => "7FFFD4",
    "azure" => "F0FFFF",
    "beige" => "F5F5DC",
    "bisque" => "FFE4C4",
    "black" => "000000",
    "blanchedalmond" => "FFEBCD",
    "blue" => "0000FF",
    "blueviolet" => "8A2BE2",
    "brown" => "A52A2A",
    "burlywood" => "DEB887",
    "cadetblue" => "5F9EA0",
    "chartreuse" => "7FFF00",
    "chocolate" => "D2691E",
    "coral" => "FF7F50",
    "cornflowerblue" => "6495ED",
    "cornsilk" => "FFF8DC",
    "crimson" => "DC143C",
    "cyan" => "00FFFF",
    "darkblue" => "00008B",
    "darkcyan" => "008B8B",
    "darkgoldenrod" => "B8860B",
    "darkgray" => "A9A9A9",
    "darkgreen" => "006400",
    "darkgrey" => "A9A9A9",
    "darkkhaki" => "BDB76B",
    "darkmagenta" => "8B008B",
    "darkolivegreen" => "556B2F",
    "darkorange" => "FF8C00",
    "darkorchid" => "9932CC",
    "darkred" => "8B0000",
    "darksalmon" => "E9967A",
    "darkseagreen" => "8FBC8F",
    "darkslateblue" => "483D8B",
    "darkslategray" => "2F4F4F",
    "darkslategrey" => "2F4F4F",
    "darkturquoise" => "00CED1",
    "darkviolet" => "9400D3",
    "deeppink" => "FF1493",
    "deepskyblue" => "00BFFF",
    "dimgray" => "696969",
    "dimgrey" => "696969",
    "dodgerblue" => "1E90FF",
    "firebrick" => "B22222",
    "floralwhite" => "FFFAF0",
    "forestgreen" => "228B22",
    "fuchsia" => "FF00FF",
    "gainsboro" => "DCDCDC",
    "ghostwhite" => "F8F8FF",
    "gold" => "FFD700",
    "goldenrod" => "DAA520",
    "gray" => "808080",
    "grey" => "808080",
    "green" => "008000",
    "greenyellow" => "ADFF2F",
    "honeydew" => "F0FFF0",
    "hotpink" => "FF69B4",
    "indianred" => "CD5C5C",
    "indigo" => "4B0082",
    "ivory" => "FFFFF0",
    "khaki" => "F0E68C",
    "lavender" => "E6E6FA",
    "lavenderblush" => "FFF0F5",
    "lawngreen" => "7CFC00",
    "lemonchiffon" => "FFFACD",
    "lightblue" => "ADD8E6",
    "lightcoral" => "F08080",
    "lightcyan" => "E0FFFF",
    "lightgoldenrodyellow" => "FAFAD2",
    "lightgray" => "D3D3D3",
    "lightgreen" => "90EE90",
    "lightgrey" => "D3D3D3",
    "lightpink" => "FFB6C1",
    "lightsalmon" => "FFA07A",
    "lightseagreen" => "20B2AA",
    "lightskyblue" => "87CEFA",
    "lightslategray" => "778899",
    "lightslategrey" => "778899",
    "lightsteelblue" => "B0C4DE",
    "lightyellow" => "FFFFE0",
    "lime" => "00FF00",
    "limegreen" => "32CD32",
    "linen" => "FAF0E6",
    "magenta" => "FF00FF",
    "maroon" => "800000",
    "mediumaquamarine" => "66CDAA",
    "mediumblue" => "0000CD",
    "mediumorchid" => "BA55D3",
    "mediumpurple" => "9370DB",
    "mediumseagreen" => "3CB371",
    "mediumslateblue" => "7B68EE",
    "mediumspringgreen" => "00FA9A",
    "mediumturquoise" => "48D1CC",
    "mediumvioletred" => "C71585",
    "midnightblue" => "191970",
    "mintcream" => "F5FFFA",
    "mistyrose" => "FFE4E1",
    "moccasin" => "FFE4B5",
    "navajowhite" => "FFDEAD",
    "navy" => "000080",
    "oldlace" => "FDF5E6",
    "olive" => "808000",
    "olivedrab" => "6B8E23",
    "orange" => "FFA500",
    "orangered" => "FF4500",
    "orchid" => "DA70D6",
    "palegoldenrod" => "EEE8AA",
    "palegreen" => "98FB98",
    "paleturquoise" => "AFEEEE",
    "palevioletred" => "DB7093",
    "papayawhip" => "FFEFD5",
    "peachpuff" => "FFDAB9",
    "peru" => "CD853F",
    "pink" => "FFC0CB",
    "plum" => "DDA0DD",
    "powderblue" => "B0E0E6",
    "purple" => "800080",
    "rebeccapurple" => "663399",
    "red" => "FF0000",
    "rosybrown" => "BC8F8F",
    "royalblue" => "4169E1",
    "saddlebrown" => "8B4513",
    "salmon" => "FA8072",
    "sandybrown" => "F4A460",
    "seagreen" => "2E8B57",
    "seashell" => "FFF5EE",
    "sienna" => "A0522D",
    "silver" => "C0C0C0",
    "skyblue" => "87CEEB",
    "slateblue" => "6A5ACD",
    "slategray" => "708090",
    "slategrey" => "708090",
    "snow" => "FFFAFA",
    "springgreen" => "00FF7F",
    "steelblue" => "4682B4",
    "tan" => "D2B48C",
    "teal" => "008080",
    "thistle" => "D8BFD8",
    "tomato" => "FF6347",
    "turquoise" => "40E0D0",
    "violet" => "EE82EE",
    "wheat" => "F5DEB3",
    "white" => "FFFFFF",
    "whitesmoke" => "F5F5F5",
    "yellow" => "FFFF00",
    "yellowgreen" => "9ACD32"
  }

  # Palette key → Google colorId is @google_color_ids; this is its inverse.
  # Google's colorIds "1" (Lavender #7986CB), "4" (Flamingo #E67C73), and "10"
  # (Basil #0B8043) have no exact palette counterpart, so they're snapped to
  # the nearest palette key by RGB distance (the same heuristic nearest_key/1
  # applies to inbound CalDAV colours) rather than dropped.
  @google_color_id_keys Map.merge(
                          Map.new(@google_color_ids, fn {key, id} -> {id, key} end),
                          %{
                            "1" => "graphite",
                            "4" => "tomato",
                            "10" => "peacock"
                          }
                        )

  @fallback_class "bg-calendar-fallback"

  @doc """
  Returns the ordered palette as a list of `{key, label, tailwind_class}` tuples.
  """
  @spec palette() :: [{key(), String.t(), String.t()}]
  def palette, do: @palette

  @doc """
  Returns the list of valid palette keys.
  """
  @spec keys() :: [key()]
  def keys, do: Enum.map(@palette, fn {key, _label, _class} -> key end)

  @doc """
  Returns the neutral class painted when no colour can be resolved.
  """
  @spec fallback_class() :: String.t()
  def fallback_class, do: @fallback_class

  @doc """
  Returns how many classes the per-integration colour rotation cycles through.
  """
  @spec rotation_size() :: pos_integer()
  def rotation_size, do: length(@rotation_classes)

  @doc """
  Returns the rotation class at `index`, counting from 1.

  Callers rotate with `rem(n, rotation_size()) + 1`, so the index is always in
  range; anything else is a caller bug and gets the neutral fallback rather
  than an exception, on the same principle as `tailwind_class/1`.
  """
  @spec rotation_class(term()) :: String.t()
  def rotation_class(index) when is_integer(index) and index > 0,
    do: Enum.at(@rotation_classes, index - 1, @fallback_class)

  def rotation_class(_other), do: @fallback_class

  @doc """
  Returns `true` when `key` is a recognised palette key.
  """
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key) when is_binary(key), do: Map.has_key?(class_map(), key)
  def valid_key?(_other), do: false

  @doc """
  Maps a palette key to its Tailwind display class.

  Returns `nil` for `nil` (so callers can fall back to the per-integration
  colour) and the neutral fallback class for any unknown value (e.g. a raw
  provider colour stored inbound).
  """
  @spec tailwind_class(term()) :: String.t() | nil
  def tailwind_class(nil), do: nil

  def tailwind_class(key) when is_binary(key),
    do: Map.get(class_map(), key, @fallback_class)

  def tailwind_class(_other), do: @fallback_class

  @doc """
  Maps a palette key to a Google Calendar `colorId`, or `nil` when the key is
  unknown (so the mapper omits `colorId` and Google keeps its default).
  """
  @spec google_color_id(term()) :: String.t() | nil
  def google_color_id(key) when is_binary(key), do: Map.get(@google_color_ids, key)
  def google_color_id(_other), do: nil

  @doc """
  Maps a palette key to a CSS3 colour name for the iCal `COLOR` property, or
  `nil` when the key is unknown (so the builder omits the `COLOR` line).
  """
  @spec css_colour(term()) :: String.t() | nil
  def css_colour(key) when is_binary(key), do: Map.get(@css_colours, key)
  def css_colour(_other), do: nil

  @doc """
  Maps a raw Google Calendar `colorId` ("1".."11") to its palette key, or `nil`
  when the id is unknown/nil. Exact inverse of the outbound `google_color_id/1`.
  """
  @spec from_google_color_id(term()) :: key() | nil
  def from_google_color_id(color_id) when is_binary(color_id),
    do: Map.get(@google_color_id_keys, color_id)

  def from_google_color_id(_other), do: nil

  @doc """
  Snaps a free-form colour (a `#RRGGBB`/`#RRGGBBAA` hex or a known CSS colour
  name) to the nearest palette key by Euclidean RGB distance. Returns `nil` for
  `nil` or an unparseable value so callers fall back to a default colour.
  """
  @spec nearest_key(term()) :: key() | nil
  def nearest_key(value) when is_binary(value) do
    case to_rgb(value) do
      nil ->
        nil

      {r, g, b} ->
        {key, _dist} =
          Enum.min_by(
            Enum.map(@rgb_anchors, fn {key, {ar, ag, ab}} ->
              {key, (r - ar) ** 2 + (g - ag) ** 2 + (b - ab) ** 2}
            end),
            fn {_key, dist} -> dist end
          )

        key
    end
  end

  def nearest_key(_other), do: nil

  defp class_map do
    Map.new(@palette, fn {key, _label, class} -> {key, class} end)
  end

  defp to_rgb(value) do
    value = value |> String.trim() |> String.downcase()

    cond do
      String.starts_with?(value, "#") -> hex_to_rgb(String.trim_leading(value, "#"))
      Map.has_key?(@css_name_hex, value) -> hex_to_rgb(Map.fetch!(@css_name_hex, value))
      true -> nil
    end
  end

  defp hex_to_rgb(hex) when byte_size(hex) == 3 do
    hex
    |> String.graphemes()
    |> Enum.map_join(&String.duplicate(&1, 2))
    |> hex_to_rgb()
  end

  defp hex_to_rgb(hex) when byte_size(hex) in [6, 8] do
    with {r, ""} <- Integer.parse(binary_part(hex, 0, 2), 16),
         {g, ""} <- Integer.parse(binary_part(hex, 2, 2), 16),
         {b, ""} <- Integer.parse(binary_part(hex, 4, 2), 16) do
      {r, g, b}
    else
      _other -> nil
    end
  end

  defp hex_to_rgb(_other), do: nil
end
