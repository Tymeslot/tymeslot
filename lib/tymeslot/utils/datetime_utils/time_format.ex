defmodule Tymeslot.Utils.DateTimeUtils.TimeFormat do
  @moduledoc """
  The single source of truth for whether a clock time renders as "2:30 PM" or
  "14:30", and for which languages expect which.

  ## How the format is decided

  Locale supplies the preset and an explicit choice supersedes it, so
  `resolve/2` is the entry point for every organiser-facing caller:

      TimeFormat.resolve(preferences.time_format, locale)

  A `nil` stored value means the organiser has never touched the setting, so
  their language decides: English gets a 12-hour clock, German, French, Italian
  and Ukrainian get a 24-hour one. Once they pick a format in settings, that
  value is stored and wins regardless of language.

  ## Audience

  This governs **organiser-facing** output only: the dashboard, the availability
  grid, and the emails addressed to the organiser. Attendees never saw this
  setting and often read in a different language from the organiser, so
  attendee-facing output is formatted from the attendee's own locale via
  `TymeslotWeb.Helpers.LocaleFormat.format_time/2`. The rule: **an explicit
  preference formats the person who set it, locale convention formats everyone
  else.**
  """

  @formats ~w(12h 24h)

  # The languages Tymeslot ships that write the time as "14:30". Everything
  # else, including an unknown or missing locale, reads as a 12-hour clock.
  @twenty_four_hour_locales ~w(de fr it uk)

  @doc "The formats a preference may store, in the order they are offered."
  @spec formats() :: [String.t()]
  def formats, do: @formats

  @doc "Whether `format` is a clock format this module understands."
  @spec valid?(term()) :: boolean()
  def valid?(format), do: format in @formats

  @doc """
  The clock format a language implies, used when the organiser has not chosen
  one. This is the table `LocaleFormat.format_time/2` renders from, so an
  attendee reading German and an organiser who left the setting alone agree.

      iex> TimeFormat.for_locale("de")
      "24h"

      iex> TimeFormat.for_locale("en")
      "12h"
  """
  @spec for_locale(String.t() | nil) :: String.t()
  def for_locale(locale) when locale in @twenty_four_hour_locales, do: "24h"
  def for_locale(_other_locale), do: "12h"

  @doc """
  Resolves the clock format to render in: the organiser's stored choice when
  they have made one, otherwise the preset their language implies.

  An unrecognised stored value is treated as no choice rather than as an error,
  so a hand-edited database row degrades to the locale preset instead of
  crashing a dashboard render.

      iex> TimeFormat.resolve("24h", "en")
      "24h"

      iex> TimeFormat.resolve(nil, "de")
      "24h"
  """
  @spec resolve(String.t() | nil, String.t() | nil) :: String.t()
  def resolve(stored, locale) do
    if valid?(stored), do: stored, else: for_locale(locale)
  end

  @doc """
  Formats a time-of-day in the given clock format.

  Accepts anything `Calendar.strftime/2` accepts (`Time`, `DateTime`,
  `NaiveDateTime`). Anything other than `"12h"` renders as 24h, so a caller may
  pass an already-resolved value straight through.

      iex> TimeFormat.format(~T[14:30:00], "12h")
      "2:30 PM"

      iex> TimeFormat.format(~T[14:30:00], "24h")
      "14:30"
  """
  @spec format(Calendar.time(), String.t() | nil) :: String.t()
  def format(time, "12h"), do: Calendar.strftime(time, "%-I:%M %p")
  def format(time, _twenty_four_hour), do: Calendar.strftime(time, "%H:%M")
end
