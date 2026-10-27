defmodule Tymeslot.Timezones.Data do
  @moduledoc """
  Timezone data aggregated from curated city lists.
  Builds all lookup maps and search indexes at compile time for O(1) access,
  one set per locale with place names (`PlaceNames`); the functions that return
  labels answer in the current Gettext locale.
  """

  alias Tymeslot.Timezones.{CountryCodes, Formatting, PlaceNames, WindowsZones}

  alias Tymeslot.Timezones.Cities.{
    Africa,
    Americas,
    Asia,
    Europe,
    Oceania
  }

  # Search aliases: common alternate names that map to timezone IDs in our list.
  # Only needed when the alias doesn't match any city or country name already
  # present in the entries (e.g. "Mumbai" won't match "Kolkata, India").
  @search_aliases %{
    "mumbai" => "Asia/Kolkata",
    "bombay" => "Asia/Kolkata",
    "calcutta" => "Asia/Kolkata",
    "new delhi" => "Asia/Kolkata",
    "delhi" => "Asia/Kolkata",
    "madras" => "Asia/Kolkata",
    "beijing" => "Asia/Shanghai",
    "peking" => "Asia/Shanghai",
    "cape town" => "Africa/Johannesburg",
    # No language in the list spells it Kiev or Kiew any more, but people
    # still type those.
    "kiev" => "Europe/Kyiv",
    "kiew" => "Europe/Kyiv",
    # Départements et collectivités d'outre-mer : la façon dont un agent les
    # nomme (« la Réunion », « les Antilles ») ou les numérote ne correspond à
    # aucun libellé de la liste, qui porte le chef-lieu.
    "la reunion" => "Indian/Reunion",
    "974" => "Indian/Reunion",
    "976" => "Indian/Mayotte",
    "971" => "America/Guadeloupe",
    "972" => "America/Martinique",
    "973" => "America/Cayenne",
    "guyane" => "America/Cayenne",
    "antilles" => "America/Martinique",
    "saigon" => "Asia/Ho_Chi_Minh",
    # Vietnam and Alberta each have a single IANA zone; the second city is an
    # alias rather than an entry, so the picker can't offer a fictional id.
    "hanoi" => "Asia/Ho_Chi_Minh",
    "calgary" => "America/Edmonton",
    "constantinople" => "Europe/Istanbul",
    "rangoon" => "Asia/Yangon",
    "burma" => "Asia/Yangon",
    "ivory coast" => "Africa/Abidjan",
    "wellington" => "Pacific/Auckland"
  }

  # Legacy IANA IDs that should normalize to current canonical IDs.
  # Only genuine renames go here — NOT link IDs like Europe/Amsterdam
  # (which are their own entries in our city lists). Browsers on older
  # ICU/CLDR data still report many of the old names via
  # Intl.DateTimeFormat().resolvedOptions().timeZone.
  @legacy_ids %{
    "Africa/Asmera" => "Africa/Asmara",
    "America/Buenos_Aires" => "America/Argentina/Buenos_Aires",
    "America/Coral_Harbour" => "America/Atikokan",
    "America/Godthab" => "America/Nuuk",
    "Asia/Calcutta" => "Asia/Kolkata",
    "Asia/Dacca" => "Asia/Dhaka",
    "Asia/Katmandu" => "Asia/Kathmandu",
    "Asia/Macao" => "Asia/Macau",
    "Asia/Rangoon" => "Asia/Yangon",
    "Asia/Saigon" => "Asia/Ho_Chi_Minh",
    "Asia/Thimbu" => "Asia/Thimphu",
    "Asia/Ulan_Bator" => "Asia/Ulaanbaatar",
    "Atlantic/Faeroe" => "Atlantic/Faroe",
    "Europe/Kiev" => "Europe/Kyiv",
    "Pacific/Enderbury" => "Pacific/Kanton",
    "Pacific/Ponape" => "Pacific/Pohnpei",
    "Pacific/Truk" => "Pacific/Chuuk"
  }

  # Aggregate all city entries from continent modules.
  @english_entries (
                     entries =
                       Americas.cities() ++
                         Europe.cities() ++
                         Asia.cities() ++
                         Africa.cities() ++
                         Oceania.cities()

                     Enum.map(entries, fn {tz_id, city, country_name, country_code} ->
                       %{
                         timezone_id: tz_id,
                         label: "#{city}, #{country_name}",
                         country_alpha3: CountryCodes.to_alpha3(country_code),
                         city: city,
                         country_name: country_name,
                         country_code: country_code
                       }
                     end)
                   )

  # The same entries once per locale, labelled in its language. Everything a
  # request reads is built here for every locale, so the language is chosen
  # when the request asks, never fixed by whichever compiled first.
  @entries_by_locale Map.new(["en" | PlaceNames.locales()], fn locale ->
                       {locale,
                        Enum.map(@english_entries, fn entry ->
                          city = PlaceNames.city(locale, entry.timezone_id) || entry.city

                          country =
                            PlaceNames.country(locale, entry.country_code) || entry.country_name

                          Map.merge(entry, %{
                            label: "#{city}, #{country}",
                            local_country: country,
                            english_label: entry.label
                          })
                        end)}
                     end)

  # Keys and queries are both folded without diacritics: a French prospect
  # types « Réunion » where the English list says "Reunion", and a German
  # types "Sao Paulo" where theirs says "São Paulo".
  fold = fn text ->
    text
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
  end

  # Ukrainian keeps Ґ, Є, І, Ї and Й as letters of their own, placed beside
  # Г, Е and И; by code point Є and І would follow Я, and folding would merge
  # Ї into І and Й into И. Its labels sort by each letter's place in the
  # alphabet; any other character sorts by its folded form, ahead of letters.
  uk_rank =
    "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя"
    |> String.graphemes()
    |> Enum.with_index()
    |> Map.new()

  sort_key = fn
    "uk", label ->
      label
      |> String.downcase()
      |> String.graphemes()
      |> Enum.map(fn char ->
        case Map.fetch(uk_rank, char) do
          {:ok, rank} -> {1, rank}
          :error -> {0, fold.(char)}
        end
      end)

    _locale, label ->
      fold.(label)
  end

  # Options list sorted alphabetically by label, accents ignored, so that
  # "Österreich" sorts among the O's rather than after "Zypern".
  @options_by_locale Map.new(@entries_by_locale, fn {locale, entries} ->
                       {locale,
                        entries
                        |> Enum.sort_by(&sort_key.(locale, &1.label))
                        |> Enum.map(fn e -> {e.label, e.timezone_id} end)}
                     end)

  # Lookup maps
  @timezone_to_country Map.new(@english_entries, fn e -> {e.timezone_id, e.country_alpha3} end)

  @labels_by_locale Map.new(@entries_by_locale, fn {locale, entries} ->
                      {locale, Map.new(entries, fn e -> {e.timezone_id, e.label} end)}
                    end)

  # Search index per locale: folded key → entry. Each entry answers to its
  # label and country in the locale, to the English ones (so a habit formed
  # on the English list keeps working) and to its IANA id; then the aliases.
  @search_index_by_locale Map.new(@entries_by_locale, fn {locale, entries} ->
                            entry_by_id = Map.new(entries, fn e -> {e.timezone_id, e} end)

                            label_index =
                              Enum.flat_map(entries, fn entry ->
                                [
                                  entry.label,
                                  entry.local_country,
                                  entry.english_label,
                                  entry.country_name,
                                  entry.timezone_id
                                ]
                                |> Enum.map(fold)
                                |> Enum.uniq()
                                |> Enum.map(&{&1, entry})
                              end)

                            alias_index =
                              Enum.flat_map(@search_aliases, fn {alias_name, tz_id} ->
                                case Map.get(entry_by_id, tz_id) do
                                  nil -> []
                                  entry -> [{alias_name, entry}]
                                end
                              end)

                            {locale, label_index ++ alias_index}
                          end)

  # Popular timezones shown when the dropdown opens without a search term.
  # Ordered by rough west-to-east sweep so the UTC offsets feel natural.
  @popular_ids [
    "America/Los_Angeles",
    "America/Denver",
    "America/Chicago",
    "America/New_York",
    "America/Sao_Paulo",
    "Europe/London",
    "Europe/Amsterdam",
    "Europe/Paris",
    "Europe/Berlin",
    "Europe/Helsinki",
    "Europe/Moscow",
    "Asia/Dubai",
    "Asia/Kolkata",
    "Asia/Bangkok",
    "Asia/Shanghai",
    "Asia/Tokyo",
    "Australia/Sydney",
    "Pacific/Auckland"
  ]

  @popular_set MapSet.new(@popular_ids)

  # Labels and ids only: an offset depends on the date it is read on, so it is
  # added when the list is asked for, never baked in when the module compiles.
  @popular_pairs_by_locale Map.new(@options_by_locale, fn {locale, options} ->
                             options_map =
                               Map.new(options, fn {_label, tz_id} = opt -> {tz_id, opt} end)

                             popular =
                               Enum.flat_map(@popular_ids, &List.wrap(Map.get(options_map, &1)))

                             rest =
                               Enum.reject(options, fn {_label, tz_id} ->
                                 MapSet.member?(@popular_set, tz_id)
                               end)

                             {locale, popular ++ rest}
                           end)

  @doc """
  Every offered zone as `{label, id}`, labelled in the current Gettext locale.
  """
  @spec all_options() :: [{String.t(), String.t()}]
  def all_options, do: Map.fetch!(@options_by_locale, locale())

  @doc """
  The zones matching `term`, as `{label, id, offset}` and labelled in the
  current Gettext locale. A term matches a city or country in that locale or in
  English, an IANA id, or a common alternate name; accents are ignored.
  """
  @spec search(String.t()) :: [{String.t(), String.t(), String.t()}]
  def search(""), do: Enum.map(Map.fetch!(@popular_pairs_by_locale, locale()), &with_offset/1)

  def search(term) do
    search_folded = fold_diacritics(term)

    @search_index_by_locale
    |> Map.fetch!(locale())
    |> Enum.filter(fn {key, _entry} -> String.contains?(key, search_folded) end)
    |> Enum.uniq_by(fn {_key, entry} -> entry.timezone_id end)
    |> Enum.take(50)
    |> Enum.map(fn {_key, entry} -> with_offset({entry.label, entry.timezone_id}) end)
  end

  defp with_offset({label, tz_id}), do: {label, tz_id, Formatting.utc_offset(tz_id)}

  # The fold the index keys were built with.
  defp fold_diacritics(text) do
    text
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
  end

  # The request's language when it has place names, English otherwise (the
  # pseudo-locale among them).
  defp locale do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    if Map.has_key?(@labels_by_locale, locale), do: locale, else: "en"
  end

  @spec country_code(String.t()) :: atom() | nil
  def country_code(timezone_id) when is_binary(timezone_id) do
    Map.get(@timezone_to_country, timezone_id)
  end

  def country_code(_other), do: nil

  @doc """
  The zone's "City, Country" label in the current Gettext locale; a valid zone
  with no entry falls back to its city segment.
  """
  @spec display_name(String.t()) :: String.t()
  def display_name(timezone_id) when is_binary(timezone_id) do
    @labels_by_locale
    |> Map.fetch!(locale())
    |> Map.get_lazy(timezone_id, fn ->
      timezone_id
      |> String.split("/")
      |> List.last()
      |> String.replace("_", " ")
    end)
  end

  def display_name(_other), do: "Unknown timezone"

  @spec normalize(term()) :: term()
  def normalize(timezone_id) when is_binary(timezone_id) do
    Map.get(@legacy_ids, timezone_id, timezone_id)
  end

  def normalize(nil), do: nil
  def normalize(other), do: other

  @doc """
  Cleans a raw timezone string from an external source (iCal TZID parameter,
  Outlook Graph `originalStartTimeZone`, etc.) into a canonical IANA ID.

  Applies, in order:

    1. Whitespace trim
    2. Surrounding double-quote strip (RFC 5545 §3.2.18 permits quoted TZID
       parameter values — Zimbra, for example, emits `TZID="Europe/Brussels"`)
    3. Second whitespace trim (in case the quotes wrapped padded content)
    4. Windows zone → IANA mapping (Microsoft Graph's `originalStartTimeZone`
       frequently carries Windows zone names like `"Romance Standard Time"`)
    5. Offset-style `GMT±HHMM` / `UTC±HH` TZID → `Etc/GMT∓N` (whole-hour
       offsets only; Apple Calendar and Outlook emit these)
    6. Legacy IANA rename (`Europe/Kiev` → `Europe/Kyiv`)

  Returns `nil` for nil, non-binary, or empty input. Does **not** validate the
  result against the curated city list — callers that need validation should
  check `valid?/1` separately, or pass the result to `DateTime.from_naive/2`
  and handle its `{:error, _}` return.
  """
  @spec sanitize(term()) :: String.t() | nil
  def sanitize(nil), do: nil

  def sanitize(timezone) when is_binary(timezone) do
    cleaned =
      timezone
      |> String.trim()
      |> String.trim("\"")
      |> String.trim()

    case cleaned do
      "" -> nil
      other -> other |> windows_to_iana() |> map_offset_tzid() |> normalize()
    end
  end

  def sanitize(_other), do: nil

  defp windows_to_iana(tz) do
    case WindowsZones.to_iana(tz) do
      nil -> tz
      iana -> iana
    end
  end

  # Some clients (Apple Calendar, Outlook) emit offset-style `TZID`s such as
  # `GMT+0200` that no time zone database recognises. Map whole-hour GMT/UTC
  # offsets to the corresponding POSIX `Etc/GMT∓N` zone — note the IANA sign
  # reversal: `Etc/GMT-2` *is* UTC+2. Sub-hour offsets and out-of-range values
  # have no `Etc/GMT` equivalent and pass through unchanged (the caller then
  # falls back to UTC). DST is intentionally not represented: an offset TZID
  # carries no DST rule, so a fixed-offset zone is the most faithful mapping.
  # A bundled `VTIMEZONE` component, when present, is the richer source and is
  # consulted ahead of this fallback by the iCal parser.
  defp map_offset_tzid(tz) do
    case Regex.run(~r/^(?:GMT|UTC)\s*([+-])(\d{1,2})(\d{2})?$/i, tz) do
      [_match, sign, hours | rest] ->
        if whole_hour?(rest), do: etc_gmt_zone(sign, String.to_integer(hours)) || tz, else: tz

      _no_match ->
        tz
    end
  end

  defp whole_hour?([]), do: true
  defp whole_hour?(["00"]), do: true
  defp whole_hour?([""]), do: true
  defp whole_hour?(_minutes), do: false

  defp etc_gmt_zone(_sign, 0), do: "Etc/UTC"
  defp etc_gmt_zone("+", hours) when hours in 1..14, do: "Etc/GMT-#{hours}"
  defp etc_gmt_zone("-", hours) when hours in 1..12, do: "Etc/GMT+#{hours}"
  defp etc_gmt_zone(_sign, _hours), do: nil

  @doc """
  Returns true when the runtime time zone database can resolve `timezone_id`.

  This is a real IANA check, so link aliases (`Asia/Calcutta`), zones with no
  curated entry (`America/Detroit`) and fixed offsets (`Etc/GMT+5`, which
  `sanitize/1` itself emits) are all valid.

  Callers asking "may I accept and store this value?" want this. It says nothing
  about whether the picker can render the zone as a "City, Country" entry: a
  valid zone with no curated entry falls back to its city segment in
  `display_name/1`, and `country_code/1` returns nil for it.
  """
  @spec valid?(term()) :: boolean()
  def valid?(timezone_id) when is_binary(timezone_id) do
    match?({:ok, _now}, DateTime.now(timezone_id))
  end

  def valid?(_other), do: false

  @spec flag_exists?(term()) :: boolean()
  def flag_exists?(nil), do: false

  def flag_exists?(country_code) when is_atom(country_code) do
    country_code in Keyword.keys(Flagpack.__info__(:functions))
  end

  def flag_exists?(_other), do: false
end
