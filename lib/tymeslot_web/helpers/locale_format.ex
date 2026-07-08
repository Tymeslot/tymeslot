defmodule TymeslotWeb.Helpers.LocaleFormat do
  @moduledoc """
  Provides locale-aware formatting for dates, times, and durations.
  Handles different formatting conventions for different languages.
  """

  @doc """
  Formats a date according to locale conventions.
  - en: January 15, 2026
  - de: 15. Januar 2026
  - uk: 15 січня 2026
  """
  @spec format_date(Calendar.date(), String.t()) :: String.t()
  def format_date(date, locale) do
    month_name = format_month_name(date.month, locale)
    day_padded = String.pad_leading(to_string(date.day), 2, "0")

    case locale do
      "en" -> "#{month_name} #{day_padded}, #{date.year}"
      "de" -> "#{date.day}. #{month_name} #{date.year}"
      "uk" -> "#{date.day} #{month_name} #{date.year}"
      "fr" -> "#{date.day} #{month_name} #{date.year}"
      "it" -> "#{date.day} #{month_name} #{date.year}"
      _other_locale -> "#{month_name} #{day_padded}, #{date.year}"
    end
  end

  @doc """
  Formats time according to locale conventions.
  - en: 02:30 PM (12-hour)
  - de: 14:30 (24-hour)
  - uk: 14:30 (24-hour)
  """
  @spec format_time(Calendar.time(), String.t()) :: String.t()
  def format_time(time, locale) do
    case locale do
      "en" -> Calendar.strftime(time, "%I:%M %p")
      "de" -> Calendar.strftime(time, "%H:%M")
      "uk" -> Calendar.strftime(time, "%H:%M")
      "fr" -> Calendar.strftime(time, "%H:%M")
      "it" -> Calendar.strftime(time, "%H:%M")
      _other_locale -> Calendar.strftime(time, "%I:%M %p")
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
  defp thousand_separator(_other_locale), do: ","

  defp decimal_separator("de"), do: ","
  defp decimal_separator("it"), do: ","
  defp decimal_separator("uk"), do: ","
  defp decimal_separator("fr"), do: ","
  defp decimal_separator(_other_locale), do: "."
end
