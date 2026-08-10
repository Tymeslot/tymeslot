defmodule TymeslotWeb.Helpers.LocaleFormat do
  @moduledoc """
  Provides locale-aware formatting for dates, times, and durations.
  Handles different formatting conventions for different languages.
  """

  alias Tymeslot.Utils.DateTimeUtils.TimeFormat

  @doc """
  Formats a date according to locale conventions.
  - en: January 15, 2026
  - de: 15. Januar 2026
  - uk: 15 січня 2026
  """
  @spec format_date(Calendar.date(), String.t()) :: String.t()
  def format_date(date, locale) do
    month_name = format_month_name(date.month, locale)
    order_date_parts(date.day, month_name, date.year, locale)
  end

  @doc """
  Orders a day, month name, and year according to locale word-order
  conventions, given a bare (unpadded) day number. Shared by `format_date/2`
  and callers that build their own day/month/year pieces (e.g. date ranges).
  Matches `format_date/2`'s per-locale padding: `en`/unknown locales
  zero-pad the day; `de`/`cs`/`uk`/`fr`/`it` do not.
  - en: April 05, 2026
  - de/cs: 5. April 2026 / 5. dubna 2026
  - uk/fr/it: 5 квітня 2026 (day before month, no period)
  """
  @spec order_date_parts(String.t() | integer(), String.t(), integer(), String.t()) :: String.t()
  def order_date_parts(day, month_name, year, locale) do
    case locale do
      loc when loc in ["de", "cs"] -> "#{day}. #{month_name} #{year}"
      loc when loc in ["uk", "fr", "it"] -> "#{day} #{month_name} #{year}"
      _other_locale -> "#{month_name} #{pad_day(day)}, #{year}"
    end
  end

  defp pad_day(day), do: day |> to_string() |> String.pad_leading(2, "0")

  @doc """
  Formats a start/end date range according to locale word-order conventions,
  without the zero-padded day that `format_date/2` applies (ranges read more
  naturally with bare day numbers, e.g. "April 10 – 12, 2026").
  - en: April 10 – 12, 2026 / April 30 – May 2, 2026
  - de/cs: 10.–12. April 2026 / 30. April – 2. Mai 2026
  - uk/fr/it: 10–12 квітня 2026 / 30 квітня – 2 травня 2026 (day before month, no period)
  """
  @spec format_date_range(Calendar.date(), Calendar.date(), String.t()) :: String.t()
  def format_date_range(start_date, end_date, locale) do
    start_month = format_month_name(start_date.month, locale)
    end_month = format_month_name(end_date.month, locale)

    case locale do
      loc when loc in ["de", "cs"] ->
        day_first_range(start_date, start_month, end_date, end_month, ".")

      loc when loc in ["uk", "fr", "it"] ->
        day_first_range(start_date, start_month, end_date, end_month, "")

      _other ->
        month_first_range(start_date, start_month, end_date, end_month)
    end
  end

  defp day_first_range(start_date, start_month, end_date, end_month, day_suffix) do
    if start_date.month == end_date.month do
      "#{start_date.day}#{day_suffix}–#{end_date.day}#{day_suffix} #{end_month} #{end_date.year}"
    else
      "#{start_date.day}#{day_suffix} #{start_month} – #{end_date.day}#{day_suffix} #{end_month} #{end_date.year}"
    end
  end

  defp month_first_range(start_date, start_month, end_date, end_month) do
    if start_date.month == end_date.month do
      "#{start_month} #{start_date.day} – #{end_date.day}, #{end_date.year}"
    else
      "#{start_month} #{start_date.day} – #{end_month} #{end_date.day}, #{end_date.year}"
    end
  end

  @doc """
  Formats time according to locale conventions.
  - en: 02:30 PM (12-hour)
  - de: 14:30 (24-hour)
  - uk: 14:30 (24-hour)

  Which languages use which clock is `TimeFormat.for_locale/1`, shared with the
  organiser's clock preference so the two can't drift apart. The hour padding
  differs on purpose: this renders "02:30 PM" for a reader who never chose a
  format, while a chosen 12-hour clock renders the more conversational "2:30 PM".
  """
  @spec format_time(Calendar.time(), String.t()) :: String.t()
  def format_time(time, locale) do
    case TimeFormat.for_locale(locale) do
      "12h" -> Calendar.strftime(time, "%I:%M %p")
      "24h" -> Calendar.strftime(time, "%H:%M")
    end
  end

  @month_names %{
    "de" => %{
      full:
        ~w(Januar Februar März April Mai Juni Juli August September Oktober November Dezember),
      short: ~w(Jan Feb März Apr Mai Jun Jul Aug Sep Okt Nov Dez)
    },
    "uk" => %{
      full:
        ~w(січня лютого березня квітня травня червня липня серпня вересня жовтня листопада грудня),
      short: ~w(січ лют бер кві тра чер лип сер вер жов лис гру)
    },
    "fr" => %{
      full:
        ~w(janvier février mars avril mai juin juillet août septembre octobre novembre décembre),
      short: ~w(janv. févr. mars avr. mai juin juil. août sept. oct. nov. déc.)
    },
    "it" => %{
      full:
        ~w(gennaio febbraio marzo aprile maggio giugno luglio agosto settembre ottobre novembre dicembre),
      short: ~w(gen feb mar apr mag giu lug ago set ott nov dic)
    },
    # Czech names a month inside a date in the genitive ("5. dubna 2026"), which
    # is the only place these are used, so the genitive is what is stored here.
    "cs" => %{
      full:
        ~w(ledna února března dubna května června července srpna září října listopadu prosince),
      short: ~w(led úno bře dub kvě čvn čvc srp zář říj lis pro)
    }
  }

  @default_month_names %{
    full:
      ~w(January February March April May June July August September October November December),
    short: ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  }

  @doc """
  Returns localized month names. Format can be `:full` (default) or `:short`.
  """
  @spec get_month_names(String.t(), :full | :short) :: [String.t()]
  def get_month_names(locale, format \\ :full) do
    @month_names
    |> Map.get(locale, @default_month_names)
    |> Map.fetch!(format)
  end

  @weekday_names %{
    "de" => %{
      full: ["Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"],
      short: ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"],
      narrow: ["S", "M", "D", "M", "D", "F", "S"]
    },
    "uk" => %{
      full: ["Неділя", "Понеділок", "Вівторок", "Середа", "Четвер", "П'ятниця", "Субота"],
      short: ["Нд", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"],
      narrow: ["Н", "П", "В", "С", "Ч", "П", "С"]
    },
    "fr" => %{
      full: ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"],
      short: ["dim", "lun", "mar", "mer", "jeu", "ven", "sam"],
      narrow: ["D", "L", "M", "M", "J", "V", "S"]
    },
    "it" => %{
      full: ["domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"],
      short: ["dom", "lun", "mar", "mer", "gio", "ven", "sab"],
      narrow: ["D", "L", "M", "M", "G", "V", "S"]
    },
    "cs" => %{
      full: ["neděle", "pondělí", "úterý", "středa", "čtvrtek", "pátek", "sobota"],
      short: ["ne", "po", "út", "st", "čt", "pá", "so"],
      narrow: ["N", "P", "Ú", "S", "Č", "P", "S"]
    }
  }

  @default_weekday_names %{
    full: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
    short: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
    narrow: ["S", "M", "T", "W", "T", "F", "S"]
  }

  @doc """
  Returns localized weekday names.
  Format can be :full, :short, or :narrow.
  """
  @spec get_weekday_names(String.t(), :full | :short | :narrow) :: [String.t()]
  def get_weekday_names(locale, format \\ :short) do
    @weekday_names
    |> Map.get(locale, @default_weekday_names)
    |> Map.fetch!(format)
  end

  @doc """
  Formats a month name based on month number (1-12), locale, and format.
  Format can be `:full` (default) or `:short`.
  """
  @spec format_month_name(1..12, String.t(), :full | :short) :: String.t()
  def format_month_name(month_num, locale, format \\ :full)

  def format_month_name(month_num, locale, format) when month_num in 1..12 do
    month_names = get_month_names(locale, format)
    Enum.at(month_names, month_num - 1)
  end

  @spec format_month_name(integer(), String.t(), :full | :short) :: String.t()
  def format_month_name(_invalid_month, _locale, _format), do: ""

  @doc """
  Formats a weekday name based on weekday number (1=Monday, 7=Sunday) and locale.
  """
  @spec format_weekday_name(1..7, String.t(), :full | :short | :narrow) :: String.t()
  def format_weekday_name(weekday_num, locale, format \\ :short)

  def format_weekday_name(weekday_num, locale, format)
      when weekday_num in 1..7 do
    weekday_names = get_weekday_names(locale, format)
    # Convert ISO weekday (1=Monday) to index (0=Sunday)
    index = if weekday_num == 7, do: 0, else: weekday_num
    Enum.at(weekday_names, index)
  end

  @spec format_weekday_name(integer(), String.t(), :full | :short | :narrow) :: String.t()
  def format_weekday_name(_invalid_weekday, _locale, _format), do: ""

  @doc """
  Formats a number according to locale conventions.
  - en: 1,234.56
  - de: 1.234,56
  - uk: 1 234,56
  """
  @spec format_number(number(), String.t()) :: String.t()
  def format_number(number, locale) do
    # Default to 2 decimal places for this helper
    formatted = :erlang.float_to_binary(number / 1.0, [{:decimals, 2}])
    [integer_part, fractional_part] = String.split(formatted, ".")

    # Add thousand separators to integer part
    integer_part_with_separators =
      integer_part
      |> String.to_charlist()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.join(thousand_separator(locale))
      |> String.reverse()

    integer_part_with_separators <> decimal_separator(locale) <> fractional_part
  end

  defp thousand_separator("de"), do: "."
  defp thousand_separator("it"), do: "."
  defp thousand_separator("uk"), do: " "
  defp thousand_separator("fr"), do: " "
  defp thousand_separator("cs"), do: " "
  defp thousand_separator(_other_locale), do: ","

  defp decimal_separator("de"), do: ","
  defp decimal_separator("it"), do: ","
  defp decimal_separator("uk"), do: ","
  defp decimal_separator("fr"), do: ","
  defp decimal_separator("cs"), do: ","
  defp decimal_separator(_other_locale), do: "."
end
