defmodule Tymeslot.BookingPages.SlugSuggestion do
  @moduledoc """
  The address the new-page dialog suggests for a page name, written as it
  would be typed: Latin letters, digits and hyphens.

  Letters of the app's languages are spelt out the way their speakers type
  them in an address: German umlauts as `ae`/`oe`/`ue`, `ß` as `ss`, Polish
  `ł` as `l`, Cyrillic by the Ukrainian national transliteration (with the
  few Russian letters it lacks), and every other accent dropped
  (Café → cafe). Anything left over that is not a letter or a digit becomes
  a hyphen.

  The suggestion always passes the page address rules
  (`Tymeslot.BookingPages.BookingPageSchema`): it is cut to the longest
  address at a hyphen, padded when too short, moved off a reserved word, and
  falls back to `page` when nothing of the name can be spelt. So the only
  error a host can see for it is a genuine clash with another of their pages
  or meeting types.
  """

  alias Tymeslot.BookingPages.BookingPageSchema

  @max_length 30
  @min_length 3
  @fallback "page"

  @spelt_out %{
    "ä" => "ae",
    "ö" => "oe",
    "ü" => "ue",
    "ß" => "ss",
    "ł" => "l",
    "đ" => "d",
    "ø" => "o",
    "æ" => "ae",
    "œ" => "oe",
    # Ukrainian (KMU 2010), then the Russian letters it lacks.
    "а" => "a",
    "б" => "b",
    "в" => "v",
    "г" => "h",
    "ґ" => "g",
    "д" => "d",
    "е" => "e",
    "є" => "ie",
    "ж" => "zh",
    "з" => "z",
    "и" => "y",
    "і" => "i",
    "ї" => "i",
    "й" => "i",
    "к" => "k",
    "л" => "l",
    "м" => "m",
    "н" => "n",
    "о" => "o",
    "п" => "p",
    "р" => "r",
    "с" => "s",
    "т" => "t",
    "у" => "u",
    "ф" => "f",
    "х" => "kh",
    "ц" => "ts",
    "ч" => "ch",
    "ш" => "sh",
    "щ" => "shch",
    "ь" => "",
    "ю" => "iu",
    "я" => "ia",
    "ё" => "e",
    "ы" => "y",
    "э" => "e",
    "ъ" => "",
    "'" => "",
    "’" => "",
    "ʼ" => ""
  }

  @spelt_out_keys Map.keys(@spelt_out)

  @doc """
  The address to suggest for `name`, or `""` while the name is blank.

      iex> from_name("Erstgespräch für Gründer")
      "erstgespraech-fuer-gruender"

      iex> from_name("Консультація")
      "konsultatsiia"
  """
  @spec from_name(String.t() | nil) :: String.t()
  def from_name(name) when is_binary(name) do
    if String.trim(name) == "", do: "", else: name |> spell() |> fit()
  end

  def from_name(_no_name), do: ""

  defp spell(name) do
    name
    |> String.normalize(:nfc)
    |> String.downcase()
    |> String.replace(@spelt_out_keys, &Map.fetch!(@spelt_out, &1))
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp fit(""), do: @fallback

  defp fit(slug) do
    slug
    |> shorten()
    |> pad()
    |> avoid_reserved()
  end

  # Cut at the last hyphen that keeps it within the limit, so no word is
  # left half spelt; a single word longer than the limit is cut where it must.
  defp shorten(slug) when byte_size(slug) <= @max_length, do: slug

  defp shorten(slug) do
    cut = binary_part(slug, 0, @max_length)

    case :binary.matches(cut, "-") do
      [] -> cut
      matches -> cut |> binary_part(0, matches |> List.last() |> elem(0)) |> String.trim("-")
    end
  end

  defp pad(slug) when byte_size(slug) < @min_length, do: slug <> "-" <> @fallback
  defp pad(slug), do: slug

  defp avoid_reserved(slug) do
    if slug in BookingPageSchema.reserved_slugs(), do: slug <> "-" <> @fallback, else: slug
  end
end
