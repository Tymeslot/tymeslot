defmodule Tymeslot.Integrations.Calendar.EventColour do
  @moduledoc """
  The single source of truth for Tymeslot's per-event colour palette.

  An event may carry a stable, provider-independent palette **key** (e.g.
  `"tomato"`) in its `:colour` field. This module maps that key to:

    * a Tailwind display class for the calendar grid (`tailwind_class/1`)
    * a Google Calendar `colorId` (`google_color_id/1`)
    * a CSS3 colour name for the CalDAV/iCal `COLOR` property (`css_colour/1`)

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
    {"banana", "Banana", "bg-calendar-8"},
    {"sage", "Sage", "bg-calendar-4"},
    {"peacock", "Peacock", "bg-calendar-5"},
    {"blueberry", "Blueberry", "bg-calendar-2"},
    {"grape", "Grape", "bg-calendar-3"},
    {"graphite", "Graphite", "bg-calendar-fallback"}
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

  defp class_map do
    Map.new(@palette, fn {key, _label, class} -> {key, class} end)
  end
end
