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

  The exceptions are `format_location/1` and `location_note/1`, which resolve
  through `dgettext/2` and so read the ambient Gettext locale. They must be
  called inside a `Gettext.with_locale/3` block. The rule: **pure formatters
  take a locale, gettext-backed helpers read the ambient one.**
  """

  alias Tymeslot.MeetingPayments.Money
  alias Tymeslot.MeetingTypes.Reminders
  alias Tymeslot.Utils.DateTimeUtils.Duration
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Helpers.LocaleFormat

  use Gettext, backend: TymeslotWeb.Gettext

  @excerpt_length 280

  @doc """
  Formats a date according to locale conventions.
  Delegates to LocaleFormat for locale-aware formatting.
  - en: 25 November 2024
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
  When a meeting starting at `start_time` (already in the recipient's zone)
  ends on a later date, "ends 01:00 AM on Tue 15 Jun" in the recipient's
  locale and clock; nil otherwise.
  """
  @spec format_next_day_end(DateTime.t(), integer() | nil, String.t(), String.t() | nil) ::
          String.t() | nil
  def format_next_day_end(%DateTime{} = start_time, duration, locale, time_format)
      when is_integer(duration) do
    finish = DateTime.add(start_time, duration, :minute)
    day = DateTime.to_date(finish)

    if Date.compare(day, DateTime.to_date(start_time)) == :gt do
      # No zone and no year: the time line already names the zone, and a
      # meeting never ends more than a few days after it starts.
      date = LocaleFormat.format_short_weekday_date(day, locale)

      Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
        dgettext("emails", "ends %{time} on %{date}",
          time: clock(finish, locale, time_format),
          date: date
        )
      end)
    end
  end

  def format_next_day_end(_start_time, _duration, _locale, _time_format), do: nil

  defp clock(finish, locale, nil), do: LocaleFormat.format_time(DateTime.to_time(finish), locale)
  defp clock(finish, _locale, time_format), do: TimeFormat.format(finish, time_format)

  @doc """
  Formats a date into a short locale-aware format.
  English: "25 Nov" (day before month, as in British English),
  French, Italian and Portuguese: "25/11", others: "25.11."
  """
  @spec format_date_short(Date.t() | DateTime.t() | NaiveDateTime.t(), String.t()) :: String.t()
  def format_date_short(%Date{} = date, "en"), do: "#{date.day} #{Calendar.strftime(date, "%b")}"
  def format_date_short(%Date{} = date, "fr"), do: "#{date.day}/#{date.month}"
  def format_date_short(%Date{} = date, "it"), do: "#{date.day}/#{date.month}"
  def format_date_short(%Date{} = date, "pt"), do: "#{date.day}/#{date.month}"
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
  Formats a datetime as a short timestamp for change-summary displays, in the
  datetime's own zone, named by its abbreviation and, outside UTC, by its
  IANA name as well: an abbreviation alone is ambiguous (IST is India,
  Ireland or Israel; CST is the US or China). The clock is always 24-hour:
  these summaries compare two instants, so a stable, unambiguous rendering
  matters more than local convention. Only the month abbreviation is
  localised.
  Example (en): "25 Jun 2026, 14:30 UTC",
  (de): "25 Jun 2026, 16:30 CEST (Europe/Berlin)"
  An all-day event's timing is a `Date.Range` of the days it covers and
  renders as a date range, since it has no clock time to show.
  Falls back to `to_string/1` for other values.
  """
  @spec format_time_short(DateTime.t() | Date.Range.t() | term(), String.t()) :: String.t()
  def format_time_short(%DateTime{} = dt, locale) do
    month = LocaleFormat.format_month_name(dt.month, locale, :short)
    day = dt.day |> to_string() |> String.pad_leading(2, "0")
    "#{day} #{month} #{dt.year}, #{Calendar.strftime(dt, "%H:%M %Z")}#{zone_name(dt)}"
  end

  def format_time_short(%Date.Range{} = days, locale), do: format_date_range(days, locale)

  def format_time_short(val, _locale), do: to_string(val)

  defp zone_name(%DateTime{time_zone: "Etc/UTC"}), do: ""
  defp zone_name(%DateTime{time_zone: zone, zone_abbr: zone}), do: ""
  defp zone_name(%DateTime{time_zone: zone}), do: " (#{zone})"

  # Formats the inclusive range of days an all-day event covers: one date for a
  # single day, otherwise the locale's range form.
  # Example (en): "September 22, 2026", "September 22 – 24, 2026"
  @spec format_date_range(Date.Range.t(), String.t()) :: String.t()
  defp format_date_range(%Date.Range{first: first, last: first}, locale),
    do: format_date(first, locale)

  defp format_date_range(%Date.Range{first: first, last: last}, locale),
    do: LocaleFormat.format_date_range(first, last, locale)

  @doc """
  Formats the time line of an all-day event, which has no clock time: "All
  day" for a single day, or naming the inclusive last day when it spans more.
  """
  @spec format_all_day(Date.t(), Date.t(), String.t()) :: String.t()
  def format_all_day(%Date{} = first, %Date{} = first, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn -> dgettext("emails", "All day") end)
  end

  def format_all_day(%Date{} = _first, %Date{} = last, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      dgettext("emails", "All day, until %{date}", date: format_date(last, locale))
    end)
  end

  @doc """
  The time line of a meeting-details map, as both parts of an email state it:
  the HTML card (`Tymeslot.Emails.Shared.Meeting.Hero`) and the plain-text body
  (`Tymeslot.Emails.Shared.TextBodyHelper`) render this one line, so the two
  cannot drift apart.

  `:start_time` is already in the recipient's zone, and that zone's name
  follows the time outside UTC, since an abbreviation alone is ambiguous. It
  is read from the start time itself, so a label can never name a zone the
  time was not shifted into;
  `:time_format` is the organiser's chosen clock, nil for every other reader.
  A meeting ending on a later day says when it ends, and an all-day event
  (`all_day: true` with `:date` and an inclusive `:last_date`) has no clock
  time at all. nil when the map carries no start time.

  Example (en): "02:30 PM IST (Asia/Kolkata)"
  """
  @spec format_meeting_time(map(), String.t()) :: String.t() | nil
  def format_meeting_time(
        %{all_day: true, date: %Date{} = first, last_date: %Date{} = last},
        locale
      ),
      do: format_all_day(first, last, locale)

  def format_meeting_time(%{start_time: %DateTime{} = start_time} = details, locale) do
    time_format = Map.get(details, :time_format)

    line = format_time(start_time, locale, time_format) <> zone_name(start_time)

    case format_next_day_end(start_time, Map.get(details, :duration), locale, time_format) do
      nil -> line
      note -> "#{line}, #{note}"
    end
  end

  def format_meeting_time(_details, _locale), do: nil

  @doc """
  A meeting's date and start time as one phrase, the time worded exactly as
  `format_meeting_time/2` words it (the recipient's clock, the zone named),
  for a time stated outside the details card, such as the one a rescheduled
  meeting moved from. Reads `:start_time` and `:time_format` only.

  Example (en): "14 January 2026 at 01:30 PM IST (Asia/Kolkata)"
  """
  @spec format_meeting_datetime(map(), String.t()) :: String.t()
  def format_meeting_datetime(%{start_time: %DateTime{} = start_time} = details, locale) do
    time =
      format_meeting_time(
        %{start_time: start_time, time_format: Map.get(details, :time_format)},
        locale
      )

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      dgettext("emails", "%{date} at %{time}", date: format_date(start_time, locale), time: time)
    end)
  end

  @doc """
  The duration of a meeting-details map: minutes for a timed meeting, the
  number of days an all-day event covers. Shared by the HTML card and the
  plain-text body, as `format_meeting_time/2` is.
  """
  @spec format_meeting_duration(map(), String.t()) :: String.t()
  def format_meeting_duration(
        %{all_day: true, date: %Date{} = first, last_date: %Date{} = last},
        locale
      ),
      do: format_day_count(first, last, locale)

  def format_meeting_duration(details, locale),
    do: format_duration(Map.get(details, :duration), locale)

  @doc """
  Formats how many days an all-day event covers, from its first and inclusive
  last day. Example (en): "1 day", "3 days"
  """
  @spec format_day_count(Date.t(), Date.t(), String.t()) :: String.t()
  def format_day_count(%Date{} = first, %Date{} = last, locale) do
    count = Date.diff(last, first) + 1

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      dngettext("emails", "%{count} day", "%{count} days", count)
    end)
  end

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
  Formats how long before a meeting a reminder goes out ("30 minutes",
  "1 hour") in `locale`, from the payload's `reminder_raw`.

  These carry the "time until" context because the label is always consumed
  after a preposition ("in %{label}", "%{label} before the meeting"). Case
  languages inflect it there: Ukrainian needs the accusative "за 1 годину",
  where `format_duration/2`'s bare duration needs the nominative "1 година".
  Same English words, different grammar, hence a separate msgctxt.

  The shared payload is built in the attendee's locale, so an email to anyone
  else formats the label here, in that recipient's locale, rather than
  reusing the payload's ready-made string.
  """
  @spec format_reminder_label(%{value: term(), unit: term()}, String.t()) :: String.t()
  def format_reminder_label(%{value: value, unit: unit}, locale) do
    value = Reminders.parse_reminder_value(value)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      unit_word =
        case Reminders.normalize_reminder_unit(unit) do
          "hours" -> dpngettext("emails", "time until", "hour", "hours", value)
          "days" -> dpngettext("emails", "time until", "day", "days", value)
          _minutes -> dpngettext("emails", "time until", "minute", "minutes", value)
        end

      "#{value} #{unit_word}"
    end)
  end

  @doc """
  Formats a complete datetime, letting an organiser's chosen clock override
  the locale convention, as `format_time/3` does for a time alone. `nil`
  behaves exactly like `format_datetime/2`.
  """
  @spec format_datetime(DateTime.t(), String.t(), String.t() | nil) :: String.t()
  def format_datetime(%DateTime{} = datetime, locale, nil), do: format_datetime(datetime, locale)

  def format_datetime(%DateTime{} = datetime, locale, time_format) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      dgettext("emails", "%{date} at %{time}",
        date: format_date(datetime, locale),
        time: format_time(datetime, locale, time_format)
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
  # A phone location chosen from a meeting type's list stores the host's label
  # with the number to call ("Phone call (+44 20 7946 0000)"), and that number
  # is the whole point of the line. Only the bare English literal older
  # releases wrote, or no string at all, falls back to the translated label.
  def format_location(%{location_type: :phone} = details) do
    case details[:location] do
      location when is_binary(location) and location not in ["", "Phone Call"] -> location
      _other -> dgettext("emails", "Phone Call")
    end
  end

  def format_location(details), do: details[:location] || dgettext("emails", "TBD")

  @doc """
  The line shown under the location of an in-person meeting whose address is
  arranged after booking, or nil for any other location.

  Worded for whoever reads the email: `audience: :host` (set by the
  organiser renders, see `Tymeslot.Emails.Shared.TemplateHelper`) is told to
  arrange it with the booker; `audience: :guest` (a guest the booker
  invited, who arranges nothing) only that it will be arranged; the booker,
  the default, that it will be arranged with them.
  Must be called within a `Gettext.with_locale` block.
  """
  @spec location_note(%{
          optional(:location_type) => atom() | nil,
          optional(:audience) => :host | :guest,
          optional(atom()) => term()
        }) :: String.t() | nil
  def location_note(%{location_type: :in_person_to_arrange, audience: :host}),
    do: dgettext("emails", "The address is to be arranged with the booker.")

  def location_note(%{location_type: :in_person_to_arrange, audience: :guest}),
    do: dgettext("emails", "The address will be arranged after booking.")

  def location_note(%{location_type: :in_person_to_arrange}),
    do: dgettext("emails", "The address will be arranged with you after booking.")

  def location_note(_details), do: nil

  @doc """
  `details` without the arranged-after-booking note: an in-person meeting
  whose address was still to be arranged reads as a plain in-person one.

  For the details of a meeting that is not going ahead, such as a
  cancellation, where there is no longer an address to arrange.
  """
  @spec without_location_note(map()) :: map()
  def without_location_note(%{location_type: :in_person_to_arrange} = details),
    do: %{details | location_type: :in_person}

  def without_location_note(details), do: details

  @doc """
  Formats an amount in minor units for an email, defaulting a missing currency
  to euros. See `Tymeslot.MeetingPayments.Money.format/3` for the symbols and
  the unrecognised-currency fallback (e.g. "HUF 175.00").

  Locale-specific thousands and decimal separators are not implemented; that
  needs a locale threaded through every call site.
  """
  @spec format_currency(integer(), String.t() | nil) :: String.t()
  def format_currency(cents, currency),
    do: Money.format(cents, currency || "eur")

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

  @doc """
  A description as a short plain-text excerpt: markup stripped, whitespace
  collapsed, and truncated so an email states it without reproducing it.
  """
  @spec plain_excerpt(String.t() | nil) :: String.t()
  def plain_excerpt(nil), do: ""

  def plain_excerpt(text) when is_binary(text) do
    text
    |> HtmlSanitizeEx.strip_tags()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(@excerpt_length)
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

  defp parse_duration_minutes(str) when is_binary(str), do: Duration.parse_minutes(str)

  defp parse_duration_minutes(_other), do: :error

  defp format_localized_duration(0), do: ""

  defp format_localized_duration(m) when m < 60 do
    "#{m} #{dngettext("emails", "minute", "minutes", m)}"
  end

  defp format_localized_duration(60), do: "1 #{dngettext("emails", "hour", "hours", 1)}"

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
