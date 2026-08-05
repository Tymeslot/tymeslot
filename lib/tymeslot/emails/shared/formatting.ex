defmodule Tymeslot.Emails.Shared.Formatting do
  @moduledoc """
  Date, time, weekday, duration, currency, location, and general text formatting
  helpers for Tymeslot emails.

  ## Locale contract

  Every formatter that produces locale-dependent output takes the recipient's
  locale as an explicit argument. There is deliberately no arity that defaults to
  English: `Calendar.strftime/2` always renders English month and meridiem names,
  so a "convenience" arity is indistinguishable at the call site from a correct
  one, and silently ships `02:30 PM` into a German email. Callers that genuinely
  want English (admin alerts) pass `"en"` and say so.

  The one exception is `format_location/1`, which resolves through `dgettext/2`
  and so reads the ambient Gettext locale. It must be called inside a
  `Gettext.with_locale/3` block. The rule: **pure formatters take a locale,
  gettext-backed helpers read the ambient one.**
  """

  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Helpers.LocaleFormat

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Formats a date according to locale conventions.
  Delegates to LocaleFormat for locale-aware formatting.
  - en: November 25, 2024
  - de: 25. November 2024
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
  Formats a time with timezone, letting an organiser's chosen clock override
  the locale convention.

  `time_format` is `nil` for every attendee-addressed email: an attendee never
  chose a clock and is often reading in a different language from the organiser,
  so their locale decides and this behaves exactly like `format_time/2`. Only
  organiser-addressed emails pass "12h" or "24h", and only then does the
  preference win. The locale stays required either way, so no call site can
  silently lose it.
  """
  @spec format_time(DateTime.t(), String.t(), String.t() | nil) :: String.t()
  def format_time(%DateTime{} = datetime, locale, nil), do: format_time(datetime, locale)

  def format_time(%DateTime{} = datetime, _locale, time_format) do
    tz = Calendar.strftime(datetime, "%Z")
    "#{TimeFormat.format(datetime, time_format)} #{tz}"
  end

  @doc """
  Formats a datetime as a short UTC timestamp for change-summary displays.
  The clock is always 24-hour and the zone always UTC — these summaries compare
  two instants, so a stable, unambiguous rendering matters more than local
  convention. Only the month abbreviation is localised.
  Example (en): "25 Jun 2026, 14:30 UTC", (de): "25 Jun 2026, 14:30 UTC"
  Falls back to `to_string/1` for non-DateTime values.
  """
  @spec format_time_short(DateTime.t() | term(), String.t()) :: String.t()
  def format_time_short(%DateTime{} = dt, locale) do
    month = LocaleFormat.format_month_name(dt.month, locale, :short)
    day = dt.day |> to_string() |> String.pad_leading(2, "0")
    "#{day} #{month} #{dt.year}, #{Calendar.strftime(dt, "%H:%M")} UTC"
  end

  def format_time_short(val, _locale), do: to_string(val)

  @doc """
  Formats a complete datetime, locale-aware.
  Example (en): "November 25, 2024 at 02:30 PM PST", (de): "25. November 2024 um 14:30 PST"
  """
  @spec format_datetime(DateTime.t(), String.t()) :: String.t()
  def format_datetime(%DateTime{} = datetime, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      dgettext("emails", "%{date} at %{time}",
        date: format_date(datetime, locale),
        time: format_time(datetime, locale)
      )
    end)
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
      sign = if cents < 0, do: "-", else: ""
      abs_cents = abs(cents)
      major = div(abs_cents, 100)
      minor = rem(abs_cents, 100)
      formatted = "#{sign}#{major}.#{String.pad_leading(Integer.to_string(minor), 2, "0")}"
      "#{symbol}#{formatted}"
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
