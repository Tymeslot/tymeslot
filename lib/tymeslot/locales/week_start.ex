defmodule Tymeslot.Locales.WeekStart do
  @moduledoc """
  Which day a visitor's week starts on: `:monday` or `:sunday`.

  The first day of the week is a property of a region, not of a language:
  `en-US` starts on Sunday and `en-GB` on Monday. So the visitor's language
  tags (`Accept-Language`, highest weight first) are read for a region
  first, and only then for a language that settles it on its own. When
  neither does (no tags, or a bare `en`), the caller falls back to the
  organiser's own week start (`Tymeslot.CalendarGrid.get_user_week_start/1`).

  Regions follow CLDR's week data: the territories listed below start on
  Sunday and every other one on Monday, CLDR's world default. The handful
  of territories CLDR starts on Saturday or Friday count as Monday too,
  since the grid offers only the two.
  """

  @type t :: :monday | :sunday

  # CLDR supplemental week data, `firstDay day="sun"`.
  @sunday_regions ~w(AG AS BD BR BS BT BW BZ CA CO DM DO ET GT GU HK HN ID IL IN
                     JM JP KE KH KR LA MH MM MO MT MX MZ NI NP PA PE PH PK PR PT
                     PY SA SG SV TH TT TW UM US VE VI WS YE ZA ZW)

  # A bare language whose speakers live overwhelmingly in Sunday-first
  # regions. `pt` is here because Tymeslot's Portuguese is Brazilian.
  @sunday_languages ~w(pt ja ko he hi th id)

  # Bare languages spoken across both kinds of region in large numbers; for
  # these only a region decides.
  @ambiguous_languages ~w(en es ar zh)

  @doc """
  The week start the visitor's language tags imply, or `nil` when they do
  not settle it.

  Only tags sharing the top tag's language are read for a region, so
  `de, en-US;q=0.5` stays a German visitor's Monday rather than borrowing
  a region from their second language.

      iex> Tymeslot.Locales.WeekStart.from_language_tags(["en-US", "en"])
      :sunday

      iex> Tymeslot.Locales.WeekStart.from_language_tags(["en", "en-GB"])
      :monday

      iex> Tymeslot.Locales.WeekStart.from_language_tags(["de"])
      :monday

      iex> Tymeslot.Locales.WeekStart.from_language_tags(["en"])
      nil
  """
  @spec from_language_tags([String.t()]) :: t() | nil
  def from_language_tags(tags) when is_list(tags) do
    case Enum.flat_map(tags, &split_tag/1) do
      [{language, _region} | _rest] = parsed ->
        parsed
        |> Enum.find_value(fn {lang, region} -> lang == language && region end)
        |> from_region_or_language(language)

      [] ->
        nil
    end
  end

  @doc """
  Parses a stored week start (`"monday"`, `"sunday"`), defaulting to
  `:monday`.
  """
  @spec parse(String.t() | nil) :: t()
  def parse("sunday"), do: :sunday
  def parse(_value), do: :monday

  defp from_region_or_language(region, _language) when is_binary(region),
    do: if(region in @sunday_regions, do: :sunday, else: :monday)

  defp from_region_or_language(nil, language) when language in @sunday_languages, do: :sunday
  defp from_region_or_language(nil, language) when language in @ambiguous_languages, do: nil
  defp from_region_or_language(nil, _language), do: :monday

  # `zh-Hant-TW` and `en_us` both reduce to a language and an optional
  # two-letter region; script and variant subtags are skipped. Anything
  # without a plausible language subtag (`*`, garbage) is dropped.
  defp split_tag(tag) do
    [language | subtags] = tag |> String.trim() |> String.downcase() |> String.split(["-", "_"])

    if language =~ ~r/^[a-z]{2,3}$/ do
      region = Enum.find(subtags, &(&1 =~ ~r/^[a-z]{2}$/))
      [{language, region && String.upcase(region)}]
    else
      []
    end
  end
end
