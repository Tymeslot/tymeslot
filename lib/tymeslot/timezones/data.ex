defmodule Tymeslot.Timezones.Data do
  @moduledoc """
  Compile-time enriched timezone data from TzExtra.
  Builds all lookup maps and option lists at compile time for O(1) access.
  """

  alias Tymeslot.Timezones.{CountryCodes, Formatting}

  # Search aliases: common city names that map to IANA IDs with different names
  @search_aliases %{
    "mumbai" => "Asia/Kolkata",
    "new delhi" => "Asia/Kolkata",
    "delhi" => "Asia/Kolkata",
    "calcutta" => "Asia/Kolkata",
    "beijing" => "Asia/Shanghai",
    "cape town" => "Africa/Johannesburg",
    "ho chi minh" => "Asia/Ho_Chi_Minh",
    "saigon" => "Asia/Ho_Chi_Minh",
    "constantinople" => "Europe/Istanbul",
    "bombay" => "Asia/Kolkata",
    "madras" => "Asia/Kolkata",
    "peking" => "Asia/Shanghai",
    "rangoon" => "Asia/Yangon",
    "burma" => "Asia/Yangon",
    "ivory coast" => "Africa/Abidjan",
    "hong kong" => "Asia/Hong_Kong",
    "wellington" => "Pacific/Auckland"
  }

  # Country overrides: timezone_id => ISO alpha-2 country code.
  # Used when TzExtra's ordering doesn't reflect the internationally recognised
  # country assignment (e.g. disputed territories).
  @country_overrides %{
    # Simferopol is the capital of Crimea, internationally recognised as Ukraine
    # despite Russian occupation since 2014. TzExtra lists Russia first.
    "Europe/Simferopol" => "UA",
    # Asia/Yangon is Myanmar's timezone; TzExtra lists Cocos Islands (CCK) first.
    "Asia/Yangon" => "MM"
  }

  # Label overrides for entries where the default derivation isn't ideal
  @label_overrides %{
    "America/Argentina/Buenos_Aires" => "Buenos Aires",
    "America/Argentina/Cordoba" => "Cordoba",
    "America/Argentina/Salta" => "Salta",
    "America/Argentina/Jujuy" => "Jujuy",
    "America/Argentina/Tucuman" => "Tucuman",
    "America/Argentina/Catamarca" => "Catamarca",
    "America/Argentina/La_Rioja" => "La Rioja",
    "America/Argentina/San_Juan" => "San Juan",
    "America/Argentina/Mendoza" => "Mendoza",
    "America/Argentina/San_Luis" => "San Luis",
    "America/Argentina/Rio_Gallegos" => "Rio Gallegos",
    "America/Argentina/Ushuaia" => "Ushuaia",
    "America/Indiana/Indianapolis" => "Indianapolis",
    "America/Indiana/Knox" => "Knox",
    "America/Indiana/Marengo" => "Marengo",
    "America/Indiana/Petersburg" => "Petersburg",
    "America/Indiana/Tell_City" => "Tell City",
    "America/Indiana/Vevay" => "Vevay",
    "America/Indiana/Vincennes" => "Vincennes",
    "America/Indiana/Winamac" => "Winamac",
    "America/Kentucky/Louisville" => "Louisville",
    "America/Kentucky/Monticello" => "Monticello",
    "America/North_Dakota/Beulah" => "Beulah",
    "America/North_Dakota/Center" => "Center",
    "America/North_Dakota/New_Salem" => "New Salem"
  }

  @enrich_entry fn entry, overrides ->
    city =
      Map.get(overrides, entry.time_zone_id) ||
        entry.time_zone_id
        |> String.split("/")
        |> List.last()
        |> String.replace("_", " ")

    %{
      timezone_id: entry.time_zone_id,
      label: "#{city}, #{entry.country.name}",
      country_alpha3: CountryCodes.to_alpha3(entry.country.code),
      city: city,
      country_name: entry.country.name,
      country_code: entry.country.code
    }
  end

  # All entries from TzExtra, enriched with city/country info.
  # A timezone_id can appear multiple times (once per country that uses it).
  @all_entries (
                 enrich = @enrich_entry
                 overrides = @label_overrides

                 TzExtra.countries_time_zones()
                 |> Enum.map(&enrich.(&1, overrides))
                 |> Enum.sort_by(& &1.label)
               )

  # Primary entry per timezone_id: first entry wins (TzExtra returns the
  # "home" country first — e.g. Belgium for Europe/Brussels), with
  # @country_overrides applied afterwards for disputed territories.
  @primary_entries (
                     enrich = @enrich_entry
                     label_overrides = @label_overrides
                     country_overrides = @country_overrides

                     all_tz_entries = TzExtra.countries_time_zones()

                     # Index all entries by {timezone_id, country_code} for override lookup
                     by_tz_and_country =
                       Map.new(all_tz_entries, fn entry ->
                         {{entry.time_zone_id, entry.country.code}, entry}
                       end)

                     all_tz_entries
                     |> Enum.reduce(%{}, fn entry, acc ->
                       Map.put_new(acc, entry.time_zone_id, entry)
                     end)
                     |> Enum.map(fn {tz_id, entry} ->
                       # Apply country override if one exists for this timezone
                       case Map.get(country_overrides, tz_id) do
                         nil ->
                           enrich.(entry, label_overrides)

                         override_code ->
                           override_entry =
                             Map.get(by_tz_and_country, {tz_id, override_code}, entry)

                           enrich.(override_entry, label_overrides)
                       end
                     end)
                     |> Enum.sort_by(& &1.label)
                   )

  # Options list uses deduplicated primary entries (one per timezone_id)
  @options Enum.map(@primary_entries, fn e -> {e.label, e.timezone_id} end)

  # Lookup maps use primary entry per timezone_id
  @timezone_to_country Map.new(@primary_entries, fn e -> {e.timezone_id, e.country_alpha3} end)
  @timezone_to_label Map.new(@primary_entries, fn e -> {e.timezone_id, e.label} end)
  @valid_ids MapSet.new(@primary_entries, fn e -> e.timezone_id end)

  # Search index uses ALL entries (so searching "Netherlands" finds Europe/Brussels)
  @search_index (
                  primary_by_id = Map.new(@primary_entries, fn e -> {e.timezone_id, e} end)

                  # Index all entries (including duplicate timezone_ids for different countries)
                  base_index =
                    Enum.map(@all_entries, fn entry ->
                      primary = Map.fetch!(primary_by_id, entry.timezone_id)
                      {String.downcase(entry.label), primary}
                    end)

                  # Add search aliases
                  alias_index =
                    Enum.flat_map(@search_aliases, fn {alias_name, tz_id} ->
                      case Map.get(primary_by_id, tz_id) do
                        nil -> []
                        entry -> [{alias_name, entry}]
                      end
                    end)

                  base_index ++ alias_index
                )

  @spec all_options() :: [{String.t(), String.t()}]
  def all_options, do: @options

  @spec search(String.t()) :: [{String.t(), String.t(), String.t()}]
  def search("") do
    @options
    |> Enum.take(50)
    |> Enum.map(fn {label, tz_id} -> {label, tz_id, Formatting.utc_offset(tz_id)} end)
  end

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
    case TzExtra.canonical_time_zone_id(timezone_id) do
      {:ok, canonical} -> canonical
      {:error, _reason} -> timezone_id
    end
  end

  def normalize(nil), do: nil
  def normalize(other), do: other

  @spec valid?(term()) :: boolean()
  def valid?(timezone_id) when is_binary(timezone_id) do
    TzExtra.time_zone_id_exists?(timezone_id)
  end

  def valid?(_other), do: false

  # Dialyzer traces through the compile-time @valid_ids constant and exposes
  # MapSet's opaque internal map type, producing a false contract_with_opaque.
  @dialyzer {:no_contracts, valid_ids: 0}
  @spec valid_ids() :: MapSet.t(String.t())
  def valid_ids, do: @valid_ids

  @spec flag_exists?(term()) :: boolean()
  def flag_exists?(nil), do: false

  def flag_exists?(country_code) when is_atom(country_code) do
    country_code in Keyword.keys(Flagpack.__info__(:functions))
  end

  def flag_exists?(_other), do: false
end
