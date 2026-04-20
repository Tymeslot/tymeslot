defmodule Tymeslot.Emails.Shared.Formatting do
  @moduledoc """
  Date, time, weekday, duration, currency, location, and general text formatting
  helpers for Tymeslot emails.
  """

  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Helpers.LocaleFormat

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Formats a date into a full readable format.
  Example: "November 25, 2024"
  """
  @spec format_date(Date.t() | DateTime.t() | NaiveDateTime.t()) :: String.t()
  def format_date(%Date{} = date) do
    Calendar.strftime(date, "%B %d, %Y")
  end

  def format_date(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_date()
    |> format_date()
  end

  def format_date(%NaiveDateTime{} = datetime) do
    datetime
    |> NaiveDateTime.to_date()
    |> format_date()
  end

  @doc """
  Formats a date according to locale conventions.
  Delegates to LocaleFormat for locale-aware formatting.
  """
  @spec format_date(Date.t() | DateTime.t() | NaiveDateTime.t(), String.t()) :: String.t()
  def format_date(%Date{} = date, locale), do: LocaleFormat.format_date(date, locale)

  def format_date(%DateTime{} = datetime, locale) do
    datetime |> DateTime.to_date() |> format_date(locale)
  end

  def format_date(%NaiveDateTime{} = datetime, locale) do
    datetime |> NaiveDateTime.to_date() |> format_date(locale)
  end

  @doc """
  Formats a date into a short readable format.
  Example: "Nov 25"
  """
  @spec format_date_short(Date.t() | DateTime.t() | NaiveDateTime.t()) :: String.t()
  def format_date_short(%Date{} = date) do
    "#{Calendar.strftime(date, "%b")} #{date.day}"
  end

  def format_date_short(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_date()
    |> format_date_short()
  end

  def format_date_short(%NaiveDateTime{} = datetime) do
    datetime
    |> NaiveDateTime.to_date()
    |> format_date_short()
  end

  @doc """
  Formats a date into a short locale-aware format.
  English: "Nov 25", others: "25.11."
  """
  @spec format_date_short(Date.t() | DateTime.t() | NaiveDateTime.t(), String.t()) :: String.t()
  def format_date_short(%Date{} = date, "en"), do: "#{Calendar.strftime(date, "%b")} #{date.day}"
  def format_date_short(%Date{} = date, "fr"), do: "#{date.day}/#{date.month}"
  def format_date_short(%Date{} = date, "it"), do: "#{date.day}/#{date.month}"
  def format_date_short(%Date{} = date, _locale), do: "#{date.day}.#{date.month}."

  def format_date_short(%DateTime{} = datetime, locale) do
    datetime |> DateTime.to_date() |> format_date_short(locale)
  end

  def format_date_short(%NaiveDateTime{} = datetime, locale) do
    datetime |> NaiveDateTime.to_date() |> format_date_short(locale)
  end

  @doc """
  Formats the weekday name for a date, locale-aware and uppercased.
  Example (en): "WEDNESDAY", (de): "MITTWOCH"
  """
  @spec format_weekday(Date.t() | DateTime.t() | NaiveDateTime.t(), String.t()) :: String.t()
  def format_weekday(%Date{} = date, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      date |> Date.day_of_week() |> weekday_name() |> String.upcase()
    end)
  end

  def format_weekday(%DateTime{} = datetime, locale),
    do: datetime |> DateTime.to_date() |> format_weekday(locale)

  def format_weekday(%NaiveDateTime{} = datetime, locale),
    do: datetime |> NaiveDateTime.to_date() |> format_weekday(locale)

  @doc """
  Formats a time with timezone.
  Example: "02:30 PM PST"
  """
  @spec format_time(DateTime.t()) :: String.t()
  def format_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%I:%M %p %Z")
  end

  @doc """
  Formats a time with timezone, locale-aware.
  Example (en): "02:30 PM PST", (de): "14:30 PST"
  """
  @spec format_time(DateTime.t(), String.t()) :: String.t()
  def format_time(%DateTime{} = datetime, locale) do
    time = DateTime.to_time(datetime)
    tz = Calendar.strftime(datetime, "%Z")
    "#{LocaleFormat.format_time(time, locale)} #{tz}"
  end

  @doc """
  Formats a time range.
  Example: "02:30 PM - 03:00 PM PST"
  """
  @spec format_time_range(DateTime.t(), DateTime.t()) :: String.t()
  def format_time_range(%DateTime{} = start_time, %DateTime{} = end_time) do
    start_str = Calendar.strftime(start_time, "%I:%M %p")
    end_str = Calendar.strftime(end_time, "%I:%M %p %Z")
    "#{start_str} - #{end_str}"
  end

  @doc """
  Formats a complete datetime.
  Example: "November 25, 2024 at 2:30 PM PST"
  """
  @spec format_datetime(DateTime.t()) :: String.t()
  def format_datetime(%DateTime{} = datetime) do
    "#{format_date(datetime)} at #{format_time(datetime)}"
  end

  @doc """
  Formats a meeting duration.
  Example: "30 minutes" or "1 hour"
  """
  @spec format_duration(integer() | String.t()) :: String.t()
  def format_duration(duration) do
    DateTimeUtils.format_duration(duration)
  end

  @doc """
  Formats a meeting duration in a locale-aware way.
  Example (en): "30 minutes", "1 hour"; (de): "30 Minuten", "1 Stunde"

  Unparseable strings are returned verbatim so callers see the raw input
  instead of a silent "0 minutes" — loud is better than wrong.
  """
  @spec format_duration(integer() | String.t(), String.t()) :: String.t()
  def format_duration(duration, locale) do
    case parse_duration_minutes(duration) do
      {:ok, minutes} ->
        Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
          format_localized_duration(minutes)
        end)

      :error when is_binary(duration) ->
        duration

      :error ->
        ""
    end
  end

  @doc """
  Translates a location label based on location_type.
  Must be called within a `Gettext.with_locale` block to produce the correct locale.
  Falls back to the raw location string, or a translated default if nil.
  """
  @spec format_location(%{
          optional(:location_type) => atom() | nil,
          optional(:location) => String.t() | nil,
          optional(atom()) => term()
        }) :: String.t()
  def format_location(%{location_type: :video}), do: dgettext("emails", "Video Call")
  def format_location(%{location_type: :phone}), do: dgettext("emails", "Phone Call")
  def format_location(details), do: details[:location] || dgettext("emails", "TBD")

  @doc """
  Formats currency based on cents (or raw units for zero-decimal currencies) and currency code.
  Falls back to prefixing with the ISO code for unrecognised currencies (e.g. "XYZ 12.34").

  # TODO: locale-specific thousands/decimal separators are not yet implemented —
  #       that requires threading a locale through all call sites and is a larger refactor.
  """
  @spec format_currency(integer(), String.t() | nil) :: String.t()
  def format_currency(cents, currency \\ "eur") do
    normalised = String.downcase(currency || "eur")

    symbol =
      case normalised do
        "usd" -> "$"
        "gbp" -> "£"
        "eur" -> "€"
        "jpy" -> "¥"
        "krw" -> "₩"
        "cad" -> "CA$"
        "aud" -> "A$"
        "chf" -> "CHF "
        other -> String.upcase(other) <> " "
      end

    if zero_decimal_currency?(normalised) do
      "#{symbol}#{cents}"
    else
      amount = cents / 100
      "#{symbol}#{:erlang.float_to_binary(amount / 1, decimals: 2)}"
    end
  end

  # ISO 4217 zero-decimal currencies — amounts are already in the major unit.
  defp zero_decimal_currency?(currency) do
    currency in ~w(jpy krw vnd bif clp djf gnf isk kmf mga pyg rwf ugx vuv xaf xof xpf)
  end

  @doc """
  Truncates text to a maximum length with ellipsis.
  """
  @spec truncate(String.t(), integer()) :: String.t()
  def truncate(text, max_length) when is_binary(text) and is_integer(max_length) do
    if String.length(text) <= max_length do
      text
    else
      String.slice(text, 0, max_length - 3) <> "..."
    end
  end

  # Private functions

  defp weekday_name(1), do: dgettext("emails", "Monday")
  defp weekday_name(2), do: dgettext("emails", "Tuesday")
  defp weekday_name(3), do: dgettext("emails", "Wednesday")
  defp weekday_name(4), do: dgettext("emails", "Thursday")
  defp weekday_name(5), do: dgettext("emails", "Friday")
  defp weekday_name(6), do: dgettext("emails", "Saturday")
  defp weekday_name(7), do: dgettext("emails", "Sunday")

  defp parse_duration_minutes(minutes) when is_integer(minutes) and minutes > 0,
    do: {:ok, minutes}

  defp parse_duration_minutes(0), do: {:ok, 0}

  defp parse_duration_minutes(str) when is_binary(str) do
    case Regex.run(~r/^\s*(\d+)\s*(?:-?\s*min(?:utes?)?)?\s*$/i, str) do
      [_full, m] -> {:ok, String.to_integer(m)}
      _no_match -> :error
    end
  end

  defp parse_duration_minutes(_other), do: :error

  defp format_localized_duration(0), do: ""

  defp format_localized_duration(m) when m < 60 do
    "#{m} #{dngettext("emails", "minute", "minutes", m)}"
  end

  defp format_localized_duration(60), do: "1 #{dngettext("emails", "hour", "hours", 1)}"
  defp format_localized_duration(90), do: "1.5 #{dngettext("emails", "hour", "hours", 2)}"

  defp format_localized_duration(m) when rem(m, 60) == 0 do
    hours = div(m, 60)
    "#{hours} #{dngettext("emails", "hour", "hours", hours)}"
  end

  defp format_localized_duration(m) do
    h = div(m, 60)
    mins = rem(m, 60)

    "#{h} #{dngettext("emails", "hour", "hours", h)} #{mins} #{dngettext("emails", "minute", "minutes", mins)}"
  end
end
