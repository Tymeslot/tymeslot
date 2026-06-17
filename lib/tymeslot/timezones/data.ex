defmodule Tymeslot.Timezones.Data do
  @moduledoc """
  Timezone data aggregated from curated city lists.
  Builds all lookup maps and search indexes at compile time for O(1) access.
  """

  alias Tymeslot.Timezones.{CountryCodes, Formatting, WindowsZones}

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
    "saigon" => "Asia/Ho_Chi_Minh",
    "constantinople" => "Europe/Istanbul",
    "rangoon" => "Asia/Yangon",
    "burma" => "Asia/Yangon",
    "ivory coast" => "Africa/Abidjan",
    "wellington" => "Pacific/Auckland"
  }

  # Legacy IANA IDs that should normalize to current canonical IDs.
  # Only genuine renames go here — NOT link IDs like Europe/Amsterdam
  # (which are their own entries in our city lists).
  @legacy_ids %{
    "Europe/Kiev" => "Europe/Kyiv"
  }

  # Aggregate all city entries from continent modules.
  @all_entries (
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

  # Options list sorted alphabetically by label
  @options @all_entries
           |> Enum.sort_by(& &1.label)
           |> Enum.map(fn e -> {e.label, e.timezone_id} end)

  # Lookup maps
  @timezone_to_country Map.new(@all_entries, fn e -> {e.timezone_id, e.country_alpha3} end)
  @timezone_to_label Map.new(@all_entries, fn e -> {e.timezone_id, e.label} end)
  @valid_ids MapSet.new(@all_entries, fn e -> e.timezone_id end)

  # Search index: lowercase label → entry, plus aliases
  @search_index (
                  entry_by_id = Map.new(@all_entries, fn e -> {e.timezone_id, e} end)

                  label_index =
                    Enum.flat_map(@all_entries, fn entry ->
                      # Index both "city, country" and "country" separately
                      [
                        {String.downcase(entry.label), entry},
                        {String.downcase(entry.country_name), entry}
                      ]
                    end)

                  alias_index =
                    Enum.flat_map(@search_aliases, fn {alias_name, tz_id} ->
                      case Map.get(entry_by_id, tz_id) do
                        nil -> []
                        entry -> [{alias_name, entry}]
                      end
                    end)

                  label_index ++ alias_index
                )

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

  @popular_options (
                     options_map = Map.new(@options, fn {_label, tz_id} = opt -> {tz_id, opt} end)

                     popular =
                       @popular_ids
                       |> Enum.flat_map(fn tz_id ->
                         case Map.get(options_map, tz_id) do
                           nil -> []
                           opt -> [opt]
                         end
                       end)
                       |> Enum.map(fn {label, tz_id} ->
                         {label, tz_id, Formatting.utc_offset(tz_id)}
                       end)

                     rest =
                       @options
                       |> Enum.reject(fn {_label, tz_id} ->
                         MapSet.member?(@popular_set, tz_id)
                       end)
                       |> Enum.map(fn {label, tz_id} ->
                         {label, tz_id, Formatting.utc_offset(tz_id)}
                       end)

                     popular ++ rest
                   )

  @spec all_options() :: [{String.t(), String.t()}]
  def all_options, do: @options

  @spec search(String.t()) :: [{String.t(), String.t(), String.t()}]
  def search(""), do: @popular_options

  def search(term) do
    search_lower = String.downcase(term)

    @search_index
    |> Enum.filter(fn {key, _entry} -> String.contains?(key, search_lower) end)
    |> Enum.uniq_by(fn {_key, entry} -> entry.timezone_id end)
    |> Enum.map(fn {_key, entry} ->
      {entry.label, entry.timezone_id, Formatting.utc_offset(entry.timezone_id)}
    end)
    |> Enum.take(50)
  end

  @spec country_code(String.t()) :: atom() | nil
  def country_code(timezone_id) when is_binary(timezone_id) do
    Map.get(@timezone_to_country, timezone_id)
  end

  def country_code(_other), do: nil

  @spec display_name(String.t()) :: String.t()
  def display_name(timezone_id) when is_binary(timezone_id) do
    Map.get_lazy(@timezone_to_label, timezone_id, fn ->
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
    5. Legacy IANA rename (`Europe/Kiev` → `Europe/Kyiv`)

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
      other -> other |> windows_to_iana() |> normalize()
    end
  end

  def sanitize(_other), do: nil

  defp windows_to_iana(tz) do
    case WindowsZones.to_iana(tz) do
      nil -> tz
      iana -> iana
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(timezone_id) when is_binary(timezone_id) do
    MapSet.member?(@valid_ids, timezone_id)
  end

  def valid?(_other), do: false

  @spec valid_ids() :: MapSet.t(String.t())
  def valid_ids, do: @valid_ids

  @spec flag_exists?(term()) :: boolean()
  def flag_exists?(nil), do: false

  def flag_exists?(country_code) when is_atom(country_code) do
    country_code in Keyword.keys(Flagpack.__info__(:functions))
  end

  def flag_exists?(_other), do: false
end
