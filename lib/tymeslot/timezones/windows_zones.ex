defmodule Tymeslot.Timezones.WindowsZones do
  @moduledoc """
  Static mapping between Windows timezone names and IANA timezone IDs: from
  Windows to IANA for what Microsoft Graph returns (`to_iana/1`), and from
  IANA to Windows for what it is sent (`from_iana/2`).

  Microsoft Graph's Outlook calendar API returns `timeZone` / `originalStartTimeZone`
  values as either IANA names (when callers set `Prefer: outlook.timezone="UTC"`)
  or Windows zone names (e.g. `"Romance Standard Time"`, `"W. Europe Standard Time"`)
  depending on how the event was created and which metadata Graph was willing
  to return.

  The table below is derived from the Unicode CLDR `windowsZones.xml` mapping
  (territory `"001"` — the default IANA zone for each Windows zone). It covers
  all 140 Windows zones documented by Microsoft as of 2026.
  """

  alias Tymeslot.Clock

  @windows_to_iana %{
    "AUS Central Standard Time" => "Australia/Darwin",
    "AUS Eastern Standard Time" => "Australia/Sydney",
    "Afghanistan Standard Time" => "Asia/Kabul",
    "Alaskan Standard Time" => "America/Anchorage",
    "Aleutian Standard Time" => "America/Adak",
    "Altai Standard Time" => "Asia/Barnaul",
    "Arab Standard Time" => "Asia/Riyadh",
    "Arabian Standard Time" => "Asia/Dubai",
    "Arabic Standard Time" => "Asia/Baghdad",
    "Argentina Standard Time" => "America/Argentina/Buenos_Aires",
    "Astrakhan Standard Time" => "Europe/Astrakhan",
    "Atlantic Standard Time" => "America/Halifax",
    "Aus Central W. Standard Time" => "Australia/Eucla",
    "Azerbaijan Standard Time" => "Asia/Baku",
    "Azores Standard Time" => "Atlantic/Azores",
    "Bahia Standard Time" => "America/Bahia",
    "Bangladesh Standard Time" => "Asia/Dhaka",
    "Belarus Standard Time" => "Europe/Minsk",
    "Bougainville Standard Time" => "Pacific/Bougainville",
    "Canada Central Standard Time" => "America/Regina",
    "Cape Verde Standard Time" => "Atlantic/Cape_Verde",
    "Caucasus Standard Time" => "Asia/Yerevan",
    "Cen. Australia Standard Time" => "Australia/Adelaide",
    "Central America Standard Time" => "America/Guatemala",
    "Central Asia Standard Time" => "Asia/Almaty",
    "Central Brazilian Standard Time" => "America/Cuiaba",
    "Central Europe Standard Time" => "Europe/Budapest",
    "Central European Standard Time" => "Europe/Warsaw",
    "Central Pacific Standard Time" => "Pacific/Guadalcanal",
    "Central Standard Time" => "America/Chicago",
    "Central Standard Time (Mexico)" => "America/Mexico_City",
    "Chatham Islands Standard Time" => "Pacific/Chatham",
    "China Standard Time" => "Asia/Shanghai",
    "Cuba Standard Time" => "America/Havana",
    "Dateline Standard Time" => "Etc/GMT+12",
    "E. Africa Standard Time" => "Africa/Nairobi",
    "E. Australia Standard Time" => "Australia/Brisbane",
    "E. Europe Standard Time" => "Europe/Chisinau",
    "E. South America Standard Time" => "America/Sao_Paulo",
    "Easter Island Standard Time" => "Pacific/Easter",
    "Eastern Standard Time" => "America/New_York",
    "Eastern Standard Time (Mexico)" => "America/Cancun",
    "Egypt Standard Time" => "Africa/Cairo",
    "Ekaterinburg Standard Time" => "Asia/Yekaterinburg",
    "FLE Standard Time" => "Europe/Kyiv",
    "Fiji Standard Time" => "Pacific/Fiji",
    "GMT Standard Time" => "Europe/London",
    "GTB Standard Time" => "Europe/Bucharest",
    "Georgian Standard Time" => "Asia/Tbilisi",
    "Greenland Standard Time" => "America/Godthab",
    "Greenwich Standard Time" => "Atlantic/Reykjavik",
    "Haiti Standard Time" => "America/Port-au-Prince",
    "Hawaiian Standard Time" => "Pacific/Honolulu",
    "India Standard Time" => "Asia/Kolkata",
    "Iran Standard Time" => "Asia/Tehran",
    "Israel Standard Time" => "Asia/Jerusalem",
    "Jordan Standard Time" => "Asia/Amman",
    "Kaliningrad Standard Time" => "Europe/Kaliningrad",
    "Korea Standard Time" => "Asia/Seoul",
    "Libya Standard Time" => "Africa/Tripoli",
    "Line Islands Standard Time" => "Pacific/Kiritimati",
    "Lord Howe Standard Time" => "Australia/Lord_Howe",
    "Magadan Standard Time" => "Asia/Magadan",
    "Magallanes Standard Time" => "America/Punta_Arenas",
    "Marquesas Standard Time" => "Pacific/Marquesas",
    "Mauritius Standard Time" => "Indian/Mauritius",
    "Middle East Standard Time" => "Asia/Beirut",
    "Montevideo Standard Time" => "America/Montevideo",
    "Morocco Standard Time" => "Africa/Casablanca",
    "Mountain Standard Time" => "America/Denver",
    "Mountain Standard Time (Mexico)" => "America/Chihuahua",
    "Myanmar Standard Time" => "Asia/Yangon",
    "N. Central Asia Standard Time" => "Asia/Novosibirsk",
    "Namibia Standard Time" => "Africa/Windhoek",
    "Nepal Standard Time" => "Asia/Kathmandu",
    "New Zealand Standard Time" => "Pacific/Auckland",
    "Newfoundland Standard Time" => "America/St_Johns",
    "Norfolk Standard Time" => "Pacific/Norfolk",
    "North Asia East Standard Time" => "Asia/Irkutsk",
    "North Asia Standard Time" => "Asia/Krasnoyarsk",
    "North Korea Standard Time" => "Asia/Pyongyang",
    "Omsk Standard Time" => "Asia/Omsk",
    "Pacific SA Standard Time" => "America/Santiago",
    "Pacific Standard Time" => "America/Los_Angeles",
    "Pacific Standard Time (Mexico)" => "America/Tijuana",
    "Pakistan Standard Time" => "Asia/Karachi",
    "Paraguay Standard Time" => "America/Asuncion",
    "Qyzylorda Standard Time" => "Asia/Qyzylorda",
    "Romance Standard Time" => "Europe/Paris",
    "Russia Time Zone 10" => "Asia/Srednekolymsk",
    "Russia Time Zone 11" => "Asia/Kamchatka",
    "Russia Time Zone 3" => "Europe/Samara",
    "Russian Standard Time" => "Europe/Moscow",
    "SA Eastern Standard Time" => "America/Cayenne",
    "SA Pacific Standard Time" => "America/Bogota",
    "SA Western Standard Time" => "America/La_Paz",
    "SE Asia Standard Time" => "Asia/Bangkok",
    "Saint Pierre Standard Time" => "America/Miquelon",
    "Sakhalin Standard Time" => "Asia/Sakhalin",
    "Samoa Standard Time" => "Pacific/Apia",
    "Sao Tome Standard Time" => "Africa/Sao_Tome",
    "Saratov Standard Time" => "Europe/Saratov",
    "Singapore Standard Time" => "Asia/Singapore",
    "South Africa Standard Time" => "Africa/Johannesburg",
    "South Sudan Standard Time" => "Africa/Juba",
    "Sri Lanka Standard Time" => "Asia/Colombo",
    "Sudan Standard Time" => "Africa/Khartoum",
    "Syria Standard Time" => "Asia/Damascus",
    "Taipei Standard Time" => "Asia/Taipei",
    "Tasmania Standard Time" => "Australia/Hobart",
    "Tocantins Standard Time" => "America/Araguaina",
    "Tokyo Standard Time" => "Asia/Tokyo",
    "Tomsk Standard Time" => "Asia/Tomsk",
    "Tonga Standard Time" => "Pacific/Tongatapu",
    "Transbaikal Standard Time" => "Asia/Chita",
    "Turkey Standard Time" => "Europe/Istanbul",
    "Turks And Caicos Standard Time" => "America/Grand_Turk",
    "US Eastern Standard Time" => "America/Indiana/Indianapolis",
    "US Mountain Standard Time" => "America/Phoenix",
    "UTC" => "Etc/UTC",
    "UTC+12" => "Etc/GMT-12",
    "UTC+13" => "Etc/GMT-13",
    "UTC-02" => "Etc/GMT+2",
    "UTC-08" => "Etc/GMT+8",
    "UTC-09" => "Etc/GMT+9",
    "UTC-11" => "Etc/GMT+11",
    "Ulaanbaatar Standard Time" => "Asia/Ulaanbaatar",
    "Venezuela Standard Time" => "America/Caracas",
    "Vladivostok Standard Time" => "Asia/Vladivostok",
    "Volgograd Standard Time" => "Europe/Volgograd",
    "W. Australia Standard Time" => "Australia/Perth",
    "W. Central Africa Standard Time" => "Africa/Lagos",
    "W. Europe Standard Time" => "Europe/Berlin",
    "W. Mongolia Standard Time" => "Asia/Hovd",
    "West Asia Standard Time" => "Asia/Tashkent",
    "West Bank Standard Time" => "Asia/Hebron",
    "West Pacific Standard Time" => "Pacific/Port_Moresby",
    "Yakutsk Standard Time" => "Asia/Yakutsk",
    "Yukon Standard Time" => "America/Whitehorse"
  }

  @doc """
  Looks up an IANA timezone ID for a Windows zone name.

  Returns `nil` if the input is not a known Windows zone — the caller is then
  free to treat the value as a (potentially already-IANA) string and let
  downstream validation handle it.
  """
  @spec to_iana(term()) :: String.t() | nil
  def to_iana(windows_name) when is_binary(windows_name) do
    Map.get(@windows_to_iana, windows_name)
  end

  def to_iana(_other), do: nil

  # The time zone database's links, from each old or alias name to the zone
  # it names (`America/Montreal` to `America/Toronto`), read from the newest
  # release kept in `priv/tz`.
  @tz_dir Path.join([__DIR__, "../../../priv/tz/tzdata*"]) |> Path.wildcard() |> Enum.max()
  @tz_link_files Enum.map(~w(backward etcetera), &Path.join(@tz_dir, &1))
  for file <- @tz_link_files, do: @external_resource(file)

  @tz_links @tz_link_files
            |> Enum.flat_map(&Regex.scan(~r/^Link\s+(\S+)\s+(\S+)/m, File.read!(&1)))
            |> Map.new(fn [_line, target, link] -> {link, target} end)

  if map_size(@tz_links) < 200,
    do: raise("read only #{map_size(@tz_links)} links from #{@tz_dir}; has its format changed?")

  # CLDR's own mapping, every territory's IANA zones included, as published
  # in `windowsZones.xml` (kept verbatim in `priv/cldr/`). CLDR names a few
  # renamed zones the old way (`Asia/Calcutta`), so each is also kept under
  # the zone its name links to; a name CLDR lists itself takes precedence.
  @cldr_path Path.join([__DIR__, "../../../priv/cldr/windowsZones.xml"])
  @external_resource @cldr_path

  @cldr_entries ~r/<mapZone other="([^"]+)" territory="[^"]+" type="([^"]+)"\/>/
                |> Regex.scan(File.read!(@cldr_path), capture: :all_but_first)
                |> Enum.flat_map(fn [windows, zones] ->
                  Enum.map(String.split(zones), &{&1, windows})
                end)

  if length(@cldr_entries) < 400,
    do:
      raise(
        "read only #{length(@cldr_entries)} zones from #{@cldr_path}; has its format changed?"
      )

  @cldr_iana_to_windows Map.merge(
                          Map.new(@cldr_entries, fn {zone, windows} ->
                            {Map.get(@tz_links, zone, zone), windows}
                          end),
                          Map.new(@cldr_entries)
                        )

  # How far, and how often, a zone's offsets are compared with a Windows
  # zone's, from the start of the year an event starts in. A week is shorter
  # than the gap between any zone's two offset changes.
  @match_span_days 2 * 365
  @match_step_days 7

  @doc """
  The Windows zone name Microsoft Graph should be given for `zone`, an IANA
  zone name, for an event starting at `anchor`; `"UTC"` when none keeps its
  offsets.

  Graph accepts every Windows zone name but only some IANA ones, and does
  not list, among others, `Europe/Madrid`, `Europe/Dublin` or
  `America/Toronto`. The answer is CLDR's (`Europe/Madrid` is
  `Romance Standard Time`), found under the zone's name, under the old name
  CLDR may still use for it, or, for a link such as `America/Montreal`,
  under the zone it links to. A zone CLDR does not name at all maps to the
  first Windows zone whose default IANA zone keeps the same UTC offsets for
  two years from the start of `anchor`'s year, changing
  them at the same instants, which is the zone Graph then expands the event
  in; that search is remembered per zone and year. A Windows zone name is
  returned as given.
  """
  @spec from_iana(String.t(), DateTime.t()) :: String.t()
  def from_iana(zone, anchor \\ Clock.utc_now()) when is_binary(zone) do
    cond do
      Map.has_key?(@windows_to_iana, zone) -> zone
      windows = Map.get(@cldr_iana_to_windows, zone) -> windows
      windows = Map.get(@cldr_iana_to_windows, Map.get(@tz_links, zone)) -> windows
      true -> remembered_match(zone, anchor.year)
    end
  end

  # A zone's match depends only on the time zone database, which a running
  # node does not change, so it is kept for the node's life. Zones and years
  # are few, and a `:persistent_term` write happens once for each.
  defp remembered_match(zone, year) do
    key = {__MODULE__, zone, year}

    case :persistent_term.get(key, :unset) do
      :unset ->
        windows =
          same_offsets(zone, DateTime.new!(Date.new!(year, 1, 1), ~T[00:00:00])) || "UTC"

        :persistent_term.put(key, windows)
        windows

      windows ->
        windows
    end
  end

  defp same_offsets(zone, from) do
    weekly = Enum.map(0..@match_span_days//@match_step_days, &DateTime.add(from, &1, :day))

    case offsets(zone, weekly) do
      [] ->
        nil

      weekly_offsets ->
        # Each change of `zone`, from the last second before it to the first
        # second after, so a zone changing at another hour does not match.
        samples = weekly ++ changes(zone, Enum.zip(weekly, weekly_offsets))
        wanted = offsets(zone, samples)

        @windows_to_iana
        |> Enum.sort()
        |> Enum.find_value(fn {windows, iana} ->
          if offsets(iana, weekly) == weekly_offsets and offsets(iana, samples) == wanted,
            do: windows
        end)
    end
  end

  defp changes(zone, weekly) do
    weekly
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [{_earlier, same}, {_later, same}] -> []
      [{earlier, from}, {later, _to}] -> first_after(zone, from, earlier, later)
    end)
  end

  # The last second still at `from` and the first one past it, in
  # `(earlier, later]`.
  defp first_after(zone, from, earlier, later) do
    if DateTime.diff(later, earlier) <= 1 do
      [earlier, later]
    else
      middle = DateTime.add(earlier, div(DateTime.diff(later, earlier), 2), :second)

      if offsets(zone, [middle]) == [from],
        do: first_after(zone, from, middle, later),
        else: first_after(zone, from, earlier, middle)
    end
  end

  # The total UTC offset of `zone` at each instant, or `[]` for a zone the
  # time zone database does not know.
  defp offsets(zone, instants) do
    instants
    |> Enum.reduce_while([], fn instant, acc ->
      case DateTime.shift_zone(instant, zone) do
        {:ok, local} -> {:cont, [local.utc_offset + local.std_offset | acc]}
        {:error, _reason} -> {:halt, []}
      end
    end)
    |> Enum.reverse()
  end
end
