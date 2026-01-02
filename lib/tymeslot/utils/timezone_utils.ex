defmodule Tymeslot.Utils.TimezoneUtils do
  @moduledoc """
  Utility functions for timezone handling, formatting, and display.
  Provides centralized timezone logic for use across the application.
  """

  alias Calendar

  @type timezone :: String.t()
  @type timezone_label :: String.t()
  @type timezone_option :: {timezone_label(), timezone()}
  @type timezone_option_with_offset :: {timezone_label(), timezone(), String.t()}
  @type country_code :: atom()

  @doc """
  Normalizes timezone names to ensure consistency.
  Maps legacy Europe/Kiev to modern Europe/Kyiv spelling.
  """
  @spec normalize_timezone(term()) :: term()
  def normalize_timezone("Europe/Kiev"), do: "Europe/Kyiv"
  def normalize_timezone(timezone) when is_binary(timezone), do: timezone
  def normalize_timezone(nil), do: nil
  def normalize_timezone(other), do: other

  @doc """
  Formats a timezone string for display with current UTC offset.
  """
  @spec format_timezone(term()) :: String.t()
  def format_timezone(timezone) when is_binary(timezone) do
    # Normalize timezone first
    normalized_tz = normalize_timezone(timezone)

    # Find the timezone in our comprehensive list
    case Enum.find(get_all_timezone_options(), fn {_label, value} -> value == normalized_tz end) do
      {label, _value} ->
        label

      nil ->
        # Fallback formatting for unknown timezones
        normalized_tz
        |> String.replace("_", " ")
        |> String.split("/")
        |> List.last()
    end
  end

  def format_timezone(_), do: "Unknown timezone"

  @doc """
  Gets the country code for a timezone to display flags.
  Maps timezone names to ISO 3166-1 alpha-3 country codes for flagpack.
  """
  @spec get_country_code_for_timezone(term()) :: country_code | nil
  def get_country_code_for_timezone(timezone) when is_binary(timezone) do
    timezone_to_country_map = %{
      # Americas
      "America/Adak" => :usa,
      "America/Anchorage" => :usa,
      "America/Los_Angeles" => :usa,
      "America/Denver" => :usa,
      "America/Chicago" => :usa,
      "America/New_York" => :usa,
      "America/Toronto" => :can,
      "America/Montreal" => :can,
      "America/Vancouver" => :can,
      "America/Mexico_City" => :mex,
      "America/Tijuana" => :mex,
      "America/Sao_Paulo" => :bra,
      "America/Argentina/Buenos_Aires" => :arg,
      "America/Santiago" => :chl,
      "America/Lima" => :per,
      "America/Bogota" => :col,
      "America/Caracas" => :ven,

      # Europe
      "Europe/London" => :gbr,
      "Europe/Dublin" => :irl,
      "Europe/Lisbon" => :prt,
      "Europe/Madrid" => :esp,
      "Europe/Paris" => :fra,
      "Europe/Amsterdam" => :nld,
      "Europe/Brussels" => :bel,
      "Europe/Berlin" => :deu,
      "Europe/Zurich" => :che,
      "Europe/Vienna" => :aut,
      "Europe/Rome" => :ita,
      "Europe/Prague" => :cze,
      "Europe/Warsaw" => :pol,
      "Europe/Stockholm" => :swe,
      "Europe/Oslo" => :nor,
      "Europe/Copenhagen" => :dnk,
      "Europe/Helsinki" => :fin,
      "Europe/Kyiv" => :ukr,
      "Europe/Kiev" => :ukr,
      "Europe/Moscow" => :rus,
      "Europe/Istanbul" => :tur,
      "Europe/Athens" => :grc,
      "Europe/Bucharest" => :rou,
      "Europe/Sofia" => :bgr,

      # Asia
      "Asia/Tokyo" => :jpn,
      "Asia/Shanghai" => :chn,
      "Asia/Hong_Kong" => :hkg,
      "Asia/Singapore" => :sgp,
      "Asia/Taipei" => :twn,
      "Asia/Seoul" => :kor,
      "Asia/Bangkok" => :tha,
      "Asia/Jakarta" => :idn,
      "Asia/Manila" => :phl,
      "Asia/Kuala_Lumpur" => :mys,
      "Asia/Mumbai" => :ind,
      "Asia/Kolkata" => :ind,
      "Asia/Delhi" => :ind,
      "Asia/Dubai" => :are,
      "Asia/Riyadh" => :sau,
      "Asia/Tehran" => :irn,
      "Asia/Baghdad" => :irq,
      "Asia/Beirut" => :lbn,
      "Asia/Jerusalem" => :isr,
      "Asia/Karachi" => :pak,
      "Asia/Dhaka" => :bgd,
      "Asia/Colombo" => :lka,
      "Asia/Kathmandu" => :npl,
      "Asia/Almaty" => :kaz,
      "Asia/Tashkent" => :uzb,
      "Asia/Bishkek" => :kgz,
      "Asia/Dushanbe" => :tjk,
      "Asia/Ashgabat" => :tkm,
      "Asia/Kabul" => :afg,
      "Asia/Yerevan" => :arm,
      "Asia/Baku" => :aze,
      "Asia/Tbilisi" => :geo,

      # Africa
      "Africa/Cairo" => :egy,
      "Africa/Johannesburg" => :zaf,
      "Africa/Lagos" => :nga,
      "Africa/Nairobi" => :ken,
      "Africa/Casablanca" => :mar,
      "Africa/Algiers" => :dza,
      "Africa/Tunis" => :tun,
      "Africa/Tripoli" => :lby,
      "Africa/Khartoum" => :sdn,
      "Africa/Addis_Ababa" => :eth,
      "Africa/Kampala" => :uga,
      "Africa/Dar_es_Salaam" => :tza,
      "Africa/Maputo" => :moz,
      "Africa/Lusaka" => :zmb,
      "Africa/Harare" => :zwe,
      "Africa/Gaborone" => :bwa,
      "Africa/Windhoek" => :nam,
      "Africa/Kinshasa" => :cod,
      "Africa/Luanda" => :ago,
      "Africa/Accra" => :gha,
      "Africa/Abidjan" => :civ,
      "Africa/Dakar" => :sen,
      "Africa/Bamako" => :mli,
      "Africa/Ouagadougou" => :bfa,
      "Africa/Niamey" => :ner,
      "Africa/Ndjamena" => :tcd,
      "Africa/Bangui" => :caf,
      "Africa/Libreville" => :gab,
      "Africa/Brazzaville" => :cog,
      "Africa/Douala" => :cmr,

      # Oceania
      "Pacific/Auckland" => :nzl,
      "Australia/Sydney" => :aus,
      "Australia/Melbourne" => :aus,
      "Australia/Brisbane" => :aus,
      "Australia/Perth" => :aus,
      "Australia/Adelaide" => :aus,
      "Australia/Darwin" => :aus,
      "Australia/Hobart" => :aus,
      "Pacific/Fiji" => :fji,
      "Pacific/Honolulu" => :usa,
      "Pacific/Pago_Pago" => :asm,
      "Pacific/Guam" => :gum,
      "Pacific/Saipan" => :mnp,
      "Pacific/Palau" => :plw,
      "Pacific/Yap" => :fsm,
      "Pacific/Truk" => :fsm,
      "Pacific/Ponape" => :fsm,
      "Pacific/Kosrae" => :fsm,
      "Pacific/Kwajalein" => :mhl,
      "Pacific/Majuro" => :mhl,
      "Pacific/Nauru" => :nru,
      "Pacific/Tarawa" => :kir,
      "Pacific/Funafuti" => :tuv,
      "Pacific/Fakaofo" => :tkl,
      "Pacific/Apia" => :wsm,
      "Pacific/Tongatapu" => :ton,
      "Pacific/Nukualofa" => :ton,
      "Pacific/Port_Moresby" => :png,
      "Pacific/Noumea" => :ncl,
      "Pacific/Efate" => :vut,
      "Pacific/Guadalcanal" => :slb,
      "Pacific/Norfolk" => :nfk
    }

    Map.get(timezone_to_country_map, normalize_timezone(timezone))
  end

  def get_country_code_for_timezone(_), do: nil

  @doc """
  Gets the current UTC offset for a timezone.
  """
  @spec get_current_utc_offset(timezone()) :: String.t()
  def get_current_utc_offset(timezone) do
    now = DateTime.utc_now()

    case DateTime.shift_zone(now, timezone) do
      {:ok, shifted_dt} ->
        # Get the UTC offset in seconds from the shifted datetime
        offset_seconds = shifted_dt.utc_offset + shifted_dt.std_offset
        format_utc_offset(offset_seconds)

      _ ->
        "UTC"
    end
  rescue
    _ -> "UTC"
  end

  @doc """
  Formats UTC offset seconds into human-readable string.
  """
  @spec format_utc_offset(integer()) :: String.t()
  def format_utc_offset(0), do: "UTC±0"

  def format_utc_offset(seconds) when seconds > 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    if minutes == 0 do
      "UTC+#{hours}"
    else
      "UTC+#{hours}:#{String.pad_leading("#{minutes}", 2, "0")}"
    end
  end

  def format_utc_offset(seconds) when seconds < 0 do
    hours = div(-seconds, 3600)
    minutes = div(rem(-seconds, 3600), 60)

    if minutes == 0 do
      "UTC-#{hours}"
    else
      "UTC-#{hours}:#{String.pad_leading("#{minutes}", 2, "0")}"
    end
  end

  @doc """
  Gets filtered timezone options based on search term.
  Returns list of {label, value, offset} tuples.
  """
  @spec get_filtered_timezone_options(String.t()) :: [timezone_option_with_offset]
  def get_filtered_timezone_options(search_term) do
    all_timezones = get_all_timezone_options()

    filtered =
      if search_term == "" do
        all_timezones
      else
        search_lower = String.downcase(search_term)

        Enum.filter(all_timezones, fn {label, _value} ->
          String.contains?(String.downcase(label), search_lower)
        end)
      end

    # Add current UTC offset for each timezone
    mapped_timezones =
      Enum.map(filtered, fn {label, value} ->
        offset = get_current_utc_offset(value)
        {label, value, offset}
      end)

    # Limit to 50 results for performance
    Enum.take(mapped_timezones, 50)
  end

  @doc """
  Gets all available timezone options as {label, value} tuples.
  """
  @spec get_all_timezone_options() :: [timezone_option]
  def get_all_timezone_options do
    [
      # Americas
      {"Adak, Alaska", "America/Adak"},
      {"Anchorage, Alaska", "America/Anchorage"},
      {"Los Angeles, California", "America/Los_Angeles"},
      {"Denver, Colorado", "America/Denver"},
      {"Chicago, Illinois", "America/Chicago"},
      {"New York, New York", "America/New_York"},
      {"Toronto, Canada", "America/Toronto"},
      {"Montreal, Canada", "America/Montreal"},
      {"Vancouver, Canada", "America/Vancouver"},
      {"Mexico City, Mexico", "America/Mexico_City"},
      {"Tijuana, Mexico", "America/Tijuana"},
      {"Sao Paulo, Brazil", "America/Sao_Paulo"},
      {"Buenos Aires, Argentina", "America/Argentina/Buenos_Aires"},
      {"Santiago, Chile", "America/Santiago"},
      {"Lima, Peru", "America/Lima"},
      {"Bogota, Colombia", "America/Bogota"},
      {"Caracas, Venezuela", "America/Caracas"},

      # Europe
      {"London, United Kingdom", "Europe/London"},
      {"Dublin, Ireland", "Europe/Dublin"},
      {"Lisbon, Portugal", "Europe/Lisbon"},
      {"Madrid, Spain", "Europe/Madrid"},
      {"Paris, France", "Europe/Paris"},
      {"Amsterdam, Netherlands", "Europe/Amsterdam"},
      {"Brussels, Belgium", "Europe/Brussels"},
      {"Berlin, Germany", "Europe/Berlin"},
      {"Zurich, Switzerland", "Europe/Zurich"},
      {"Vienna, Austria", "Europe/Vienna"},
      {"Rome, Italy", "Europe/Rome"},
      {"Prague, Czech Republic", "Europe/Prague"},
      {"Warsaw, Poland", "Europe/Warsaw"},
      {"Stockholm, Sweden", "Europe/Stockholm"},
      {"Oslo, Norway", "Europe/Oslo"},
      {"Copenhagen, Denmark", "Europe/Copenhagen"},
      {"Helsinki, Finland", "Europe/Helsinki"},
      {"Kyiv, Ukraine", "Europe/Kyiv"},
      {"Moscow, Russia", "Europe/Moscow"},
      {"Istanbul, Turkey", "Europe/Istanbul"},
      {"Athens, Greece", "Europe/Athens"},
      {"Bucharest, Romania", "Europe/Bucharest"},
      {"Sofia, Bulgaria", "Europe/Sofia"},

      # Asia
      {"Tokyo, Japan", "Asia/Tokyo"},
      {"Seoul, South Korea", "Asia/Seoul"},
      {"Beijing, China", "Asia/Shanghai"},
      {"Shanghai, China", "Asia/Shanghai"},
      {"Hong Kong", "Asia/Hong_Kong"},
      {"Taipei, Taiwan", "Asia/Taipei"},
      {"Singapore", "Asia/Singapore"},
      {"Kuala Lumpur, Malaysia", "Asia/Kuala_Lumpur"},
      {"Jakarta, Indonesia", "Asia/Jakarta"},
      {"Bangkok, Thailand", "Asia/Bangkok"},
      {"Ho Chi Minh City, Vietnam", "Asia/Ho_Chi_Minh"},
      {"Manila, Philippines", "Asia/Manila"},
      {"Mumbai, India", "Asia/Kolkata"},
      {"New Delhi, India", "Asia/Kolkata"},
      {"Colombo, Sri Lanka", "Asia/Colombo"},
      {"Dhaka, Bangladesh", "Asia/Dhaka"},
      {"Karachi, Pakistan", "Asia/Karachi"},
      {"Dubai, UAE", "Asia/Dubai"},
      {"Riyadh, Saudi Arabia", "Asia/Riyadh"},
      {"Tehran, Iran", "Asia/Tehran"},
      {"Baghdad, Iraq", "Asia/Baghdad"},
      {"Tashkent, Uzbekistan", "Asia/Tashkent"},
      {"Almaty, Kazakhstan", "Asia/Almaty"},

      # Africa
      {"Cairo, Egypt", "Africa/Cairo"},
      {"Lagos, Nigeria", "Africa/Lagos"},
      {"Johannesburg, South Africa", "Africa/Johannesburg"},
      {"Cape Town, South Africa", "Africa/Johannesburg"},
      {"Nairobi, Kenya", "Africa/Nairobi"},
      {"Addis Ababa, Ethiopia", "Africa/Addis_Ababa"},
      {"Casablanca, Morocco", "Africa/Casablanca"},
      {"Tunis, Tunisia", "Africa/Tunis"},
      {"Algiers, Algeria", "Africa/Algiers"},

      # Oceania
      {"Sydney, Australia", "Australia/Sydney"},
      {"Melbourne, Australia", "Australia/Melbourne"},
      {"Brisbane, Australia", "Australia/Brisbane"},
      {"Perth, Australia", "Australia/Perth"},
      {"Adelaide, Australia", "Australia/Adelaide"},
      {"Auckland, New Zealand", "Pacific/Auckland"},
      {"Wellington, New Zealand", "Pacific/Auckland"},
      {"Honolulu, Hawaii", "Pacific/Honolulu"},
      {"Fiji", "Pacific/Fiji"},

      # Atlantic
      {"Reykjavik, Iceland", "Atlantic/Reykjavik"},
      {"Azores, Portugal", "Atlantic/Azores"}
    ]
  end

  @doc """
  Formats duration string for display.
  """
  @spec format_duration(term()) :: String.t()
  def format_duration(duration_string) when is_binary(duration_string) do
    case Regex.run(~r/^(\d+)min$/, duration_string) do
      [_, minutes_str] ->
        minutes = String.to_integer(minutes_str)
        format_minutes(minutes)

      _ ->
        "Unknown duration"
    end
  end

  def format_duration(_), do: "Unknown duration"

  # Helper function to format minutes into human-readable string
  @spec format_minutes(non_neg_integer()) :: String.t()
  defp format_minutes(1), do: "1 minute"
  defp format_minutes(minutes) when minutes < 60, do: "#{minutes} minutes"
  defp format_minutes(60), do: "1 hour"
  defp format_minutes(90), do: "1.5 hours"
  defp format_minutes(120), do: "2 hours"
  defp format_minutes(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)} hours"

  defp format_minutes(minutes) do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)
    format_hours_and_minutes(hours, mins)
  end

  @spec format_hours_and_minutes(non_neg_integer(), non_neg_integer()) :: String.t()
  defp format_hours_and_minutes(hours, mins) do
    hour_text = "#{hours} hour#{if hours > 1, do: "s", else: ""}"
    minute_text = "#{mins} minute#{if mins > 1, do: "s", else: ""}"
    "#{hour_text} #{minute_text}"
  end

  @doc """
  Formats date string for display.
  """
  @spec format_date(term()) :: String.t()
  def format_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        Calendar.strftime(date, "%B %d, %Y")

      _ ->
        date_string
    end
  end

  def format_date(_), do: "Invalid date"

  @doc """
  Checks if a flag function exists for the given country code.
  Returns true if the flag can be rendered, false otherwise.
  """
  @spec flag_exists?(term()) :: boolean()
  def flag_exists?(nil), do: false

  def flag_exists?(country_code) when is_atom(country_code) do
    # Check if the function exists in Flagpack's exported functions
    country_code in Keyword.keys(Flagpack.__info__(:functions))
  end

  def flag_exists?(_), do: false
end
