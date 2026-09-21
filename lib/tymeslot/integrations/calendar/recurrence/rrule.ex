defmodule Tymeslot.Integrations.Calendar.Recurrence.RRule do
  @moduledoc """
  Builds and parses RFC-5545 RRULE strings for the calendar grid's recurrence
  editor. Pure data transformations — no side effects.

  The supported surface matches the recurrence editor UI: a frequency
  (daily/weekly/monthly/yearly), an `INTERVAL` ("every N"), an optional `BYDAY`
  weekday selection for weekly rules, and one of two mutually-exclusive end
  conditions — `COUNT` (after N occurrences) or `UNTIL` (on a date). Complex
  rules (BYSETPOS, BYMONTH, multiple BYxxx parts) are intentionally out of
  scope; `parse/2` ignores tokens it does not understand rather than failing.

  The canonical option map shape used by both functions:

      %{
        freq: :daily | :weekly | :monthly | :yearly,
        interval: pos_integer() | nil,
        by_day: [:mo | :tu | :we | :th | :fr | :sa | :su],
        count: pos_integer() | nil,
        until: Date.t() | nil
      }

  ## `UNTIL` and the event's timezone

  `:until` is the calendar date the organiser picked, which is a *local* date:
  it has no timezone of its own. On the wire it is written differently
  depending on the event it bounds (RFC 5545 §3.3.10, "UNTIL MUST be the same
  value type as DTSTART"):

    * an all-day event's `DTSTART` is a DATE, so `UNTIL` is a bare `YYYYMMDD`,
      zone-free in both directions;
    * a timed event's `DTSTART` is a DATE-TIME, so `UNTIL` is an *instant* in
      UTC — the end of the chosen day in the event's own timezone.

  That second form is why `build/2`, `parse/2` and `retarget/2` all take a
  `:timezone`: end-of-day in Los Angeles and end-of-day in Auckland are
  different instants, and both fall on a UTC date the organiser never picked.
  Stamping `T235959Z` on the local date instead ends the series a day early
  west of UTC and a day late east of it. The option is threaded through all
  three so the value written and the value read back agree, which also makes
  `retarget/2` idempotent.

  Without a `:timezone` the UTC day is used in both directions, which is the
  right answer for a rule that is already expressed in UTC (an Outlook range,
  a legacy stored rule) and the wrong one for an organiser's local date.
  """

  alias Tymeslot.Utils.DateTimeUtils

  @type freq :: :daily | :weekly | :monthly | :yearly
  @type weekday :: :mo | :tu | :we | :th | :fr | :sa | :su
  @type opts :: %{
          optional(:freq) => freq(),
          optional(:interval) => pos_integer() | nil,
          optional(:by_day) => [weekday()],
          optional(:count) => pos_integer() | nil,
          optional(:until) => Date.t() | nil
        }

  @freq_to_token %{daily: "DAILY", weekly: "WEEKLY", monthly: "MONTHLY", yearly: "YEARLY"}
  @token_to_freq %{
    "DAILY" => :daily,
    "WEEKLY" => :weekly,
    "MONTHLY" => :monthly,
    "YEARLY" => :yearly
  }

  @weekday_to_token %{
    mo: "MO",
    tu: "TU",
    we: "WE",
    th: "TH",
    fr: "FR",
    sa: "SA",
    su: "SU"
  }
  @token_to_weekday Map.new(@weekday_to_token, fn {atom, token} -> {token, atom} end)

  @end_of_day ~T[23:59:59]
  @utc "Etc/UTC"

  # See `until_date/2`: an UNTIL ending in this is a local date stamped with
  # end-of-day UTC, not an instant to be shifted into the event's timezone.
  @legacy_utc_end_of_day "T235959Z"

  @doc """
  Builds an RFC-5545 RRULE string from the canonical option map.

  Parts are emitted in a stable order: `FREQ`, `INTERVAL` (only when > 1),
  `BYDAY` (only when non-empty), then the end condition. `COUNT` wins over
  `UNTIL` when both are supplied.

  The optional `all_day:` keyword controls the `UNTIL` value type (RFC 5545
  §3.3.10): when `true`, UNTIL is emitted as a bare date (`YYYYMMDD`) to match
  the DATE-form `DTSTART` of an all-day event. When `false` (the default),
  UNTIL is the instant that ends `:until` in `timezone:`, written in UTC, so
  the chosen calendar date is fully included wherever the organiser is.

  ## Options
    - `:all_day` — boolean, default `false`
    - `:timezone` — the event's timezone, used to resolve a timed `UNTIL`.
      Defaults to `nil`, which ends the day in UTC.
  """
  @spec build(opts(), keyword()) :: String.t()
  def build(opts, extra \\ []) do
    all_day = Keyword.get(extra, :all_day, false)
    timezone = Keyword.get(extra, :timezone)

    [
      build_freq(opts),
      build_interval(opts),
      build_by_day(opts),
      build_end_condition(opts, all_day, timezone)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(";")
  end

  @doc """
  Parses an RRULE string into the canonical option map.

  Lenient: a leading `RRULE:` prefix is stripped, unknown tokens are ignored,
  and only keys that are present in the string appear in the result.

  `:until` comes back as the organiser's local calendar date, which for a
  DATE-TIME `UNTIL` means the date its UTC instant falls on in `timezone:`.

  ## Options
    - `:timezone` — the event's timezone, used to read a DATE-TIME `UNTIL`
      back as a local date. Defaults to `nil`, which reads it as a UTC date.
  """
  @spec parse(String.t(), keyword()) :: opts()
  def parse(rrule, opts \\ []) when is_binary(rrule) do
    rrule
    |> strip_prefix()
    |> String.split(";", trim: true)
    |> Enum.reduce(%{}, &parse_token/2)
    |> resolve_until(Keyword.get(opts, :timezone))
  end

  @doc """
  Fits a rule's `UNTIL` to the event it repeats.

  The recurrence editor composes a rule before the event's all-day flag and
  start date are final, so a rule has to be checked against the event it is
  saved with rather than the one the form showed when the end date was
  picked. Two things are checked:

    * `UNTIL` must not fall before `:start_date`, or the series would have
      no occurrences at all (`{:error, :until_before_start}`); the check is
      skipped when no start date is given;
    * `UNTIL` must have the value type of `DTSTART` (RFC 5545 §3.3.10), so it
      is rewritten as a bare date for an all-day event and as an end-of-day
      instant for a timed one, as `build/2` would emit it.

  Only the `UNTIL` part is rewritten; every other part, including ones
  `parse/2` does not understand, is kept as it was. A `nil` rule stays `nil`.

  The rule is read back in `timezone:` before it is rewritten in it, so
  retargeting the same rule twice is a no-op rather than walking its end date
  one day further each time.

  ## Options
    - `:all_day` — boolean, default `false`
    - `:start_date` — the event's start date, `Date.t()` or `nil`
    - `:timezone` — the event's timezone, default `nil` (the UTC day)
  """
  @spec retarget(String.t() | nil, keyword()) ::
          {:ok, String.t() | nil} | {:error, :until_before_start}
  def retarget(nil, _opts), do: {:ok, nil}

  def retarget(rrule, opts) when is_binary(rrule) do
    all_day = Keyword.get(opts, :all_day, false)
    timezone = Keyword.get(opts, :timezone)

    case parse(rrule, timezone: timezone) do
      %{until: until} ->
        with :ok <- validate_until_after_start(until, Keyword.get(opts, :start_date)) do
          {:ok, replace_until(rrule, format_until(until, all_day, timezone))}
        end

      _no_until ->
        {:ok, rrule}
    end
  end

  defp validate_until_after_start(until, %Date{} = start_date) do
    if Date.compare(until, start_date) == :lt, do: {:error, :until_before_start}, else: :ok
  end

  defp validate_until_after_start(_until, _no_start), do: :ok

  defp replace_until(rrule, until_value) do
    {prefix, body} =
      case rrule do
        "RRULE:" <> body -> {"RRULE:", body}
        body -> {"", body}
      end

    parts =
      body
      |> String.split(";", trim: true)
      |> Enum.map(fn part ->
        if until_part?(part), do: "UNTIL=" <> until_value, else: part
      end)

    prefix <> Enum.join(parts, ";")
  end

  defp until_part?(part) do
    case String.split(part, "=", parts: 2) do
      [key, _value] -> String.upcase(key) == "UNTIL"
      _other -> false
    end
  end

  # --- build helpers ---

  defp build_freq(%{freq: freq}) when is_map_key(@freq_to_token, freq),
    do: "FREQ=#{@freq_to_token[freq]}"

  defp build_freq(_opts), do: nil

  defp build_interval(%{interval: interval}) when is_integer(interval) and interval > 1,
    do: "INTERVAL=#{interval}"

  defp build_interval(_opts), do: nil

  defp build_by_day(%{by_day: [_first | _rest] = days}) do
    tokens =
      days
      |> Enum.map(&Map.get(@weekday_to_token, &1))
      |> Enum.reject(&is_nil/1)

    if tokens == [], do: nil, else: "BYDAY=#{Enum.join(tokens, ",")}"
  end

  defp build_by_day(_opts), do: nil

  defp build_end_condition(%{count: count}, _all_day, _timezone)
       when is_integer(count) and count > 0,
       do: "COUNT=#{count}"

  defp build_end_condition(%{until: %Date{} = until}, all_day, timezone),
    do: "UNTIL=#{format_until(until, all_day, timezone)}"

  defp build_end_condition(_opts, _all_day, _timezone), do: nil

  # RFC 5545 §3.3.10: UNTIL MUST be the same value type as DTSTART.
  # All-day events use DATE-form DTSTART, so UNTIL must also be a bare date,
  # which is zone-free by definition.
  # Timed events use DATE-TIME DTSTART, so UNTIL is the instant that ends the
  # chosen day in the event's own timezone, written in UTC.
  defp format_until(%Date{} = date, true, _timezone), do: Date.to_iso8601(date, :basic)

  defp format_until(%Date{} = date, _all_day, timezone) do
    date
    |> end_of_day_utc(timezone)
    |> DateTime.to_iso8601(:basic)
  end

  # `create_datetime_safe/3` applies the project-wide rule for a wall-clock
  # time that a DST transition makes ambiguous or non-existent, and falls back
  # to UTC when the timezone is not one tzdata knows.
  defp end_of_day_utc(date, timezone) when is_binary(timezone) do
    date
    |> DateTimeUtils.create_datetime_safe(@end_of_day, timezone)
    |> DateTime.shift_zone!(@utc)
  end

  defp end_of_day_utc(date, _no_timezone), do: DateTime.new!(date, @end_of_day, @utc)

  # --- parse helpers ---

  @doc """
  Strips a leading `RRULE:` prefix from an RRULE string, if present.

  Used by the iCal builder and Google event mapper to ensure exactly one
  `RRULE:` prefix is emitted regardless of whether the stored rule already
  carries one (Google's normaliser keeps the prefix on read; CalDAV and Outlook
  store the bare rule body).
  """
  @spec strip_prefix(String.t()) :: String.t()
  def strip_prefix("RRULE:" <> rest), do: rest
  def strip_prefix(rrule), do: rrule

  defp parse_token(token, acc) do
    case String.split(token, "=", parts: 2) do
      [key, value] -> apply_token(String.upcase(key), value, acc)
      _other -> acc
    end
  end

  defp apply_token("FREQ", value, acc) do
    case Map.get(@token_to_freq, String.upcase(value)) do
      nil -> acc
      freq -> Map.put(acc, :freq, freq)
    end
  end

  defp apply_token("INTERVAL", value, acc) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> Map.put(acc, :interval, int)
      _other -> acc
    end
  end

  defp apply_token("BYDAY", value, acc) do
    days =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&Map.get(@token_to_weekday, String.upcase(&1)))
      |> Enum.reject(&is_nil/1)

    if days == [], do: acc, else: Map.put(acc, :by_day, days)
  end

  defp apply_token("COUNT", value, acc) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> Map.put(acc, :count, int)
      _other -> acc
    end
  end

  # The raw value is carried through the reduce and resolved once, in
  # `resolve_until/2`, because reading it needs the timezone and none of the
  # other tokens do.
  defp apply_token("UNTIL", value, acc), do: Map.put(acc, :until, value)

  defp apply_token(_unknown, _value, acc), do: acc

  defp resolve_until(%{until: raw} = parsed, timezone) do
    case until_date(raw, timezone) do
      {:ok, date} -> %{parsed | until: date}
      :error -> Map.delete(parsed, :until)
    end
  end

  defp resolve_until(parsed, _timezone), do: parsed

  # A DATE-TIME UNTIL is a UTC instant, so the date the organiser picked is the
  # one it falls on in the event's timezone. Anything else — a bare DATE, a
  # form this parser does not recognise — is read as the date it spells.
  #
  # `T235959Z` is the exception, and it is a legacy marker rather than an
  # instant. Rules written before UNTIL carried the event's timezone stamped
  # the organiser's local date with a literal end-of-day *UTC*, so reading one
  # back through a timezone shifts it onto the next local day everywhere east
  # of UTC — silently extending the series, and baking that extension in as
  # soon as anything rewrites the rule. `Outlook.RecurrenceConverter` also
  # builds this form from a Graph `endDate`, which is likewise a local date.
  #
  # The form is safe to special-case because it is never ambiguous: end-of-day
  # in a zero-offset zone is the only case this module itself writes as
  # `T235959Z`, and there the instant and the date it spells are the same day.
  # Every other zone produces some other wall-clock time.
  defp until_date(value, timezone) do
    if String.ends_with?(value, @legacy_utc_end_of_day) do
      basic_date(value)
    else
      case local_date_of_instant(value, timezone) do
        {:ok, date} -> {:ok, date}
        :error -> basic_date(value)
      end
    end
  end

  defp local_date_of_instant(value, timezone) when is_binary(timezone) do
    with {:ok, instant, _offset} <- DateTime.from_iso8601(value, Calendar.ISO, :basic),
         {:ok, local} <- DateTime.shift_zone(instant, timezone) do
      {:ok, DateTime.to_date(local)}
    else
      _other -> :error
    end
  end

  defp local_date_of_instant(_value, _no_timezone), do: :error

  defp basic_date(value) do
    with <<y::binary-4, m::binary-2, d::binary-2, _rest::binary>> <- String.slice(value, 0, 10),
         {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {day, ""} <- Integer.parse(d),
         {:ok, date} <- Date.new(year, month, day) do
      {:ok, date}
    else
      _other -> :error
    end
  end
end
