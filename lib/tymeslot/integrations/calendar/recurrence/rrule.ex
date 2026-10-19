defmodule Tymeslot.Integrations.Calendar.Recurrence.RRule do
  @moduledoc """
  The one reader and writer of RFC 5545 `RRULE` values.

  `parse/1` reads a rule into a `%RRule{}` holding every part the expander
  follows (`FREQ`, `INTERVAL`, `COUNT`, `UNTIL`, `BYDAY` with ordinals,
  `BYMONTHDAY`, `BYMONTH`, `BYSETPOS`, `WKST`); every other part is kept as
  written under `:other`, so a caller can tell a rule it cannot follow in
  full, and `format/1` writes the rule back with those parts unchanged.

  The calendar grid's recurrence editor works on a narrower view,
  `options/2`: a frequency, an `INTERVAL` ("every N"), a `BYDAY` weekday
  selection for weekly rules, and one of two mutually-exclusive end
  conditions, `COUNT` (after N occurrences) or `UNTIL` (on a date). `build/2`
  writes that view back, keeping the parts of the rule being edited that the
  editor does not show (`:keep`).

  The canonical option map shape:

      %{
        freq: :daily | :weekly | :monthly | :yearly,
        interval: pos_integer() | nil,
        by_day: [:mo | :tu | :we | :th | :fr | :sa | :su],
        count: pos_integer() | nil,
        until: Date.t() | nil
      }

  ## `UNTIL` and the event's timezone

  `:until` in the option map is the calendar date the organiser picked, which
  is a *local* date: it has no timezone of its own. On the wire it is written
  differently depending on the event it bounds (RFC 5545 §3.3.10, "UNTIL MUST
  be the same value type as DTSTART"):

    * an all-day event's `DTSTART` is a DATE, so `UNTIL` is a bare `YYYYMMDD`,
      zone-free in both directions;
    * a timed event's `DTSTART` is a DATE-TIME, so `UNTIL` is an *instant* in
      UTC — the end of the chosen day in the event's own timezone.

  That second form is why `build/2`, `options/2` and `retarget/2` all take a
  `:timezone`: end-of-day in Los Angeles and end-of-day in Auckland are
  different instants, and both fall on a UTC date the organiser never picked.
  Stamping `T235959Z` on the local date instead ends the series a day early
  west of UTC and a day late east of it. The option is threaded through all
  three so the value written and the value read back agree, which also makes
  `retarget/2` idempotent. `RRule.Until` holds the reading and writing, and
  `until_instant/2` reads the value in the same zone for the expander.

  Without a `:timezone` the UTC day is used in both directions, which is the
  right answer for a rule that is already expressed in UTC (an Outlook range,
  a legacy stored rule) and the wrong one for an organiser's local date.
  """

  alias Tymeslot.Integrations.Calendar.Recurrence.RRule.Until

  @type freq :: :daily | :weekly | :monthly | :yearly
  @type weekday :: :mo | :tu | :we | :th | :fr | :sa | :su
  @type opts :: %{
          optional(:freq) => freq(),
          optional(:interval) => pos_integer() | nil,
          optional(:by_day) => [weekday()],
          optional(:count) => pos_integer() | nil,
          optional(:until) => Date.t() | nil
        }

  @typedoc """
  A parsed rule. Weekdays are ISO numbers (1 is Monday), and each `BYDAY`
  entry is `{ordinal, weekday}` with `ordinal` nil for every such weekday
  (`MO`) and counted from the end when negative (`-1FR`). `:until` is the
  value as written (see `until_instant/2`); `:week_start` is nil when the
  rule states no `WKST` (Monday, by RFC 5545). `:other` holds every other
  part as `{name, value}`, in the order written.
  """
  @type t :: %__MODULE__{
          freq: freq(),
          interval: pos_integer(),
          count: non_neg_integer() | nil,
          until: String.t() | nil,
          by_day: [{integer() | nil, 1..7}] | nil,
          by_month_day: [integer()] | nil,
          by_month: [1..12] | nil,
          by_set_pos: [integer()] | nil,
          week_start: 1..7 | nil,
          other: [{String.t(), String.t()}]
        }

  @known_parts ~w(FREQ INTERVAL COUNT UNTIL BYDAY BYMONTHDAY BYMONTH BYSETPOS WKST)

  @enforce_keys [:freq]
  defstruct [
    :freq,
    :count,
    :until,
    :by_day,
    :by_month_day,
    :by_month,
    :by_set_pos,
    :week_start,
    interval: 1,
    other: []
  ]

  @freq_to_token %{daily: "DAILY", weekly: "WEEKLY", monthly: "MONTHLY", yearly: "YEARLY"}
  @token_to_freq Map.new(@freq_to_token, fn {freq, token} -> {token, freq} end)

  @utc "Etc/UTC"

  @weekday_tokens ~w(MO TU WE TH FR SA SU)
  @token_to_iso @weekday_tokens |> Enum.with_index(1) |> Map.new()
  @iso_to_token Map.new(@token_to_iso, fn {token, iso} -> {iso, token} end)
  @weekday_atoms ~w(mo tu we th fr sa su)a
  @atom_to_iso @weekday_atoms |> Enum.with_index(1) |> Map.new()
  @iso_to_atom Map.new(@atom_to_iso, fn {atom, iso} -> {iso, atom} end)

  @doc """
  Parses an `RRULE` value, with or without its `RRULE:` prefix.

  `:error` for a rule without a known `FREQ` or with an `INTERVAL` below 1,
  which RFC 5545 does not allow and which would never move forward. A value
  that is not a number, or is out of range, is dropped from a list part
  (`BYMONTHDAY=1,40` reads as `[1]`); a part left empty is absent.
  """
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(rrule) when is_binary(rrule) do
    parts =
      rrule
      |> strip_prefix()
      |> String.split(";", trim: true)
      |> Enum.flat_map(&split_part/1)

    fields = Map.new(parts)

    with {:ok, freq} <- parse_freq(fields["FREQ"]),
         interval when interval > 0 <- parse_int(fields["INTERVAL"], 1) do
      {:ok,
       %__MODULE__{
         freq: freq,
         interval: interval,
         count: parse_int(fields["COUNT"], nil),
         until: fields["UNTIL"],
         by_day: parse_by_day(fields["BYDAY"]),
         by_month_day: parse_int_list(fields["BYMONTHDAY"], -31..31),
         by_month: parse_int_list(fields["BYMONTH"], 1..12),
         by_set_pos: parse_int_list(fields["BYSETPOS"], -366..366),
         week_start: Map.get(@token_to_iso, String.upcase(fields["WKST"] || "")),
         other: Enum.reject(parts, fn {name, _value} -> name in @known_parts end)
       }}
    else
      _invalid -> :error
    end
  end

  @doc """
  The rule among a series' recurrence lines (`RRULE:`, `EXDATE`, `RDATE`, in
  any order, as Google lists them), without its prefix; nil when none is a
  rule.
  """
  @spec from_lines([String.t()] | nil) :: String.t() | nil
  def from_lines(lines) when is_list(lines) do
    Enum.find_value(lines, fn
      "RRULE:" <> rule -> rule
      _other_line -> nil
    end)
  end

  def from_lines(_lines), do: nil

  @doc """
  Writes a rule back as an `RRULE` value without its prefix. Parts come in a
  stable order, `FREQ`, `INTERVAL` (only when above 1), `BYMONTH`,
  `BYMONTHDAY`, `BYDAY`, `BYSETPOS`, `WKST`, the parts under `:other` as
  written, then the end condition.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = rule) do
    [
      {"FREQ", Map.get(@freq_to_token, rule.freq)},
      {"INTERVAL", if(rule.interval > 1, do: Integer.to_string(rule.interval))},
      {"BYMONTH", join_ints(rule.by_month)},
      {"BYMONTHDAY", join_ints(rule.by_month_day)},
      {"BYDAY", format_by_day(rule.by_day)},
      {"BYSETPOS", join_ints(rule.by_set_pos)},
      {"WKST", Map.get(@iso_to_token, rule.week_start)}
    ]
    |> Enum.concat(rule.other)
    |> Enum.concat([
      {"COUNT", rule.count && Integer.to_string(rule.count)},
      {"UNTIL", rule.until}
    ])
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Enum.map_join(";", fn {name, value} -> name <> "=" <> value end)
  end

  @doc """
  The last instant `rule` may start an occurrence at, its `UNTIL` read in
  `zone`, the zone the series' occurrences are stepped in (see
  `RRule.Until.instant/2`). `nil` when the rule has no readable `UNTIL`.
  """
  @spec until_instant(t(), String.t()) :: DateTime.t() | nil
  def until_instant(%__MODULE__{until: nil}, _zone), do: nil
  def until_instant(%__MODULE__{until: until}, zone), do: Until.instant(until, zone)

  @doc """
  Builds an `RRULE` value from the editor's option map.

  Parts are emitted in a stable order: `FREQ`, `INTERVAL` (only when > 1),
  `BYDAY` (only when non-empty), then the end condition. `COUNT` wins over
  `UNTIL` when both are supplied.

  ## Options
    - `:all_day` — boolean, default `false`. When `true`, `UNTIL` is a bare
      date (`YYYYMMDD`) to match the DATE-form `DTSTART` of an all-day event
      (RFC 5545 §3.3.10); otherwise it is the instant that ends `:until` in
      `:timezone`, written in UTC, so the chosen calendar date is fully
      included wherever the organiser is.
    - `:timezone` — the event's timezone, used to resolve a timed `UNTIL`.
      Defaults to `nil`, which ends the day in UTC.
    - `:keep` — the rule being edited, or `nil`. The parts of it the editor
      does not show are kept on top of the options:
        * always, `WKST` and every part that is not a `BY` part;
        * while the frequency stays the same, every `BY` part too
          (`BYMONTH`, `BYMONTHDAY`, `BYDAY`, `BYSETPOS`, and ones `parse/1`
          does not follow such as `BYHOUR`), except that a weekly rule takes
          its `BYDAY` from the options, since the editor shows its weekdays,
          and drops its `BYSETPOS`, which picked among the old days;
        * a rule that changes frequency drops every `BY` part, which
          belonged to the old period.
      A `BYSETPOS` left with no other `BY` part to pick among is dropped, as
      RFC 5545 §3.3.10 allows it only beside one.
  """
  @spec build(opts(), keyword()) :: String.t()
  def build(opts, extra \\ []) do
    all_day = Keyword.get(extra, :all_day, false)
    timezone = Keyword.get(extra, :timezone)

    opts
    |> from_options(all_day, timezone)
    |> keep_parts(Keyword.get(extra, :keep))
    |> format()
  end

  @doc """
  Reads a rule into the editor's option map.

  Lenient: a rule `parse/1` cannot read gives an empty map, and only the keys
  the editor shows appear: `:interval` only above 1, `:by_day` only for the
  plain weekdays (`MO`, not `2MO`), `:count` only above 0.

  `:until` comes back as the organiser's local calendar date, which for a
  DATE-TIME `UNTIL` means the date its UTC instant falls on in `timezone:`.

  ## Options
    - `:timezone` — the event's timezone, used to read a DATE-TIME `UNTIL`
      back as a local date. Defaults to `nil`, which reads it as a UTC date.
  """
  @spec options(String.t() | t(), keyword()) :: opts()
  def options(rule, opts \\ [])

  def options(rrule, opts) when is_binary(rrule) do
    case parse(rrule) do
      {:ok, rule} -> options(rule, opts)
      :error -> %{}
    end
  end

  def options(%__MODULE__{} = rule, opts) do
    by_day = for {nil, iso} <- rule.by_day || [], do: Map.fetch!(@iso_to_atom, iso)

    [
      freq: rule.freq,
      interval: if(rule.interval > 1, do: rule.interval),
      by_day: if(by_day != [], do: by_day),
      count: if(is_integer(rule.count) and rule.count > 0, do: rule.count),
      until: local_until(rule.until, Keyword.get(opts, :timezone))
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
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
  `options/2` does not show, is kept as it was. A `nil` rule stays `nil`.

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

    case options(rrule, timezone: timezone) do
      %{until: until} ->
        with :ok <- validate_until_after_start(until, Keyword.get(opts, :start_date)) do
          {:ok, replace_until(rrule, Until.format(until, all_day, timezone))}
        end

      _no_until ->
        {:ok, rrule}
    end
  end

  @doc """
  Ends a rule just before `boundary`, the start of the first occurrence it
  must no longer generate: its `COUNT` or `UNTIL` gives way to an `UNTIL`
  one step earlier, in the value type the event's `DTSTART` calls for (RFC
  5545 §3.3.10):

    * a `Date`, for an all-day event: the day before, `YYYYMMDD`;
    * a `DateTime`, for a timed event whose `DTSTART` is zoned or UTC: the
      instant a second earlier, in UTC, `YYYYMMDDTHHMMSSZ`;
    * a `NaiveDateTime`, for a floating event: the wall clock a second
      earlier, `YYYYMMDDTHHMMSS`.

  The new `UNTIL` takes the place of the end the rule had, or follows its
  other parts when it had none; every other part is kept as written.
  """
  @spec end_before(String.t(), Date.t() | DateTime.t() | NaiveDateTime.t()) :: String.t()
  def end_before(rrule, boundary) when is_binary(rrule) do
    replace_end(rrule, "UNTIL=" <> until_before(boundary))
  end

  @doc """
  Takes `occurrences` off a rule's `COUNT`, for the part of a series that
  starts that many occurrences later. A rule without a `COUNT` is returned
  as it is. The count never falls below one.
  """
  @spec reduce_count(String.t(), non_neg_integer()) :: String.t()
  def reduce_count(rrule, occurrences) when is_binary(rrule) and occurrences >= 0 do
    case options(rrule) do
      %{count: count} -> replace_end(rrule, "COUNT=#{max(count - occurrences, 1)}")
      _no_count -> rrule
    end
  end

  defp until_before(%Date{} = date), do: date |> Date.add(-1) |> Date.to_iso8601(:basic)

  defp until_before(%DateTime{} = instant) do
    instant
    |> DateTime.add(-1, :second)
    |> DateTime.shift_zone!(@utc)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601(:basic)
  end

  defp until_before(%NaiveDateTime{} = wall) do
    wall
    |> NaiveDateTime.add(-1, :second)
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601(:basic)
  end

  # Puts `end_part` where the rule's first COUNT or UNTIL stood, dropping any
  # other, or after every other part when it had neither.
  defp replace_end(rrule, end_part) do
    {prefix, body} = split_prefix(rrule)
    parts = String.split(body, ";", trim: true)

    parts =
      case Enum.find_index(parts, &end_part?/1) do
        nil ->
          parts ++ [end_part]

        index ->
          parts
          |> List.replace_at(index, end_part)
          |> Enum.with_index()
          |> Enum.reject(fn {part, at} -> at != index and end_part?(part) end)
          |> Enum.map(&elem(&1, 0))
      end

    prefix <> Enum.join(parts, ";")
  end

  defp end_part?(part), do: part_key(part) in ["COUNT", "UNTIL"]

  defp part_key(part) do
    case String.split(part, "=", parts: 2) do
      [key, _value] -> String.upcase(key)
      _other -> nil
    end
  end

  defp split_prefix("RRULE:" <> body), do: {"RRULE:", body}
  defp split_prefix(body), do: {"", body}

  defp validate_until_after_start(until, %Date{} = start_date) do
    if Date.compare(until, start_date) == :lt, do: {:error, :until_before_start}, else: :ok
  end

  defp validate_until_after_start(_until, _no_start), do: :ok

  defp replace_until(rrule, until_value) do
    {prefix, body} = split_prefix(rrule)

    parts =
      body
      |> String.split(";", trim: true)
      |> Enum.map(fn part ->
        if part_key(part) == "UNTIL", do: "UNTIL=" <> until_value, else: part
      end)

    prefix <> Enum.join(parts, ";")
  end

  # --- build helpers ---

  defp from_options(opts, all_day, timezone) do
    count = opts[:count]
    count = if is_integer(count) and count > 0, do: count

    %__MODULE__{
      freq: if(is_map_key(@freq_to_token, opts[:freq]), do: opts[:freq]),
      interval:
        if(is_integer(opts[:interval]) and opts[:interval] > 1, do: opts[:interval], else: 1),
      by_day: options_by_day(opts[:by_day]),
      count: count,
      until:
        if(is_nil(count) and is_struct(opts[:until], Date),
          do: Until.format(opts[:until], all_day, timezone)
        )
    }
  end

  defp options_by_day([_first | _rest] = days) do
    case for(day <- days, iso = Map.get(@atom_to_iso, day), do: {nil, iso}) do
      [] -> nil
      by_day -> by_day
    end
  end

  defp options_by_day(_days), do: nil

  defp keep_parts(built, kept) when is_binary(kept) do
    case parse(kept) do
      {:ok, %{freq: :weekly} = kept} when built.freq == :weekly ->
        without_lone_set_pos(%{
          built
          | by_month: kept.by_month,
            by_month_day: kept.by_month_day,
            week_start: kept.week_start,
            other: kept.other
        })

      {:ok, %{freq: freq} = kept} when freq == built.freq ->
        without_lone_set_pos(%{
          built
          | by_month: kept.by_month,
            by_month_day: kept.by_month_day,
            by_set_pos: kept.by_set_pos,
            by_day: kept.by_day,
            week_start: kept.week_start,
            other: kept.other
        })

      {:ok, kept} ->
        other = Enum.reject(kept.other, fn {name, _value} -> by_part?(name) end)
        %{built | week_start: kept.week_start, other: other}

      :error ->
        built
    end
  end

  defp keep_parts(built, _no_rule), do: built

  defp without_lone_set_pos(%{by_set_pos: nil} = rule), do: rule

  defp without_lone_set_pos(rule) do
    if rule.by_day || rule.by_month_day || rule.by_month ||
         Enum.any?(rule.other, fn {name, _value} -> by_part?(name) end),
       do: rule,
       else: %{rule | by_set_pos: nil}
  end

  defp by_part?(name), do: String.starts_with?(name, "BY")

  defp format_by_day(nil), do: nil

  defp format_by_day(by_day) do
    Enum.map_join(by_day, ",", fn {ordinal, iso} ->
      "#{ordinal}#{Map.fetch!(@iso_to_token, iso)}"
    end)
  end

  defp join_ints(nil), do: nil
  defp join_ints(values), do: Enum.join(values, ",")

  # --- parse helpers ---

  @doc """
  Strips a leading `RRULE:` prefix from an RRULE string, if present.

  Used by the iCal builder and Google event mapper to ensure exactly one
  `RRULE:` prefix is emitted regardless of whether the stored rule already
  carries one (every provider now stores the bare rule body, but rows cached
  from Google before that carry the prefix).
  """
  @spec strip_prefix(String.t()) :: String.t()
  def strip_prefix("RRULE:" <> rest), do: rest
  def strip_prefix(rrule), do: rrule

  defp split_part(part) do
    case String.split(part, "=", parts: 2) do
      [name, value] -> [{String.upcase(name), value}]
      _no_value -> []
    end
  end

  defp parse_freq(nil), do: :error

  defp parse_freq(token) do
    case Map.fetch(@token_to_freq, String.upcase(token)) do
      {:ok, freq} -> {:ok, freq}
      :error -> :error
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {n, ""} -> n
      _other -> default
    end
  end

  defp parse_by_day(nil), do: nil

  defp parse_by_day(value) do
    days =
      value
      |> String.split(",")
      |> Enum.flat_map(fn day ->
        case Regex.run(~r/^([+-]?\d{1,2})?([A-Z]{2})$/, day |> String.trim() |> String.upcase()) do
          [_match, ordinal, token] when is_map_key(@token_to_iso, token) ->
            ordinal_day(ordinal, Map.fetch!(@token_to_iso, token))

          _other ->
            []
        end
      end)

    if days == [], do: nil, else: days
  end

  defp ordinal_day("", weekday), do: [{nil, weekday}]

  defp ordinal_day(ordinal, weekday) do
    case Integer.parse(ordinal) do
      {n, ""} when n != 0 -> [{n, weekday}]
      _invalid -> []
    end
  end

  defp parse_int_list(nil, _valid), do: nil

  defp parse_int_list(value, valid) do
    values =
      value
      |> String.split(",")
      |> Enum.flat_map(fn item ->
        case Integer.parse(String.trim(item)) do
          {n, ""} when n != 0 -> if n in valid, do: [n], else: []
          _invalid -> []
        end
      end)

    if values == [], do: nil, else: values
  end

  defp local_until(nil, _timezone), do: nil

  defp local_until(until, timezone) do
    case Until.local_date(until, timezone) do
      {:ok, date} -> date
      :error -> nil
    end
  end
end
