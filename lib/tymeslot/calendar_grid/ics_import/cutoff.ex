defmodule Tymeslot.CalendarGrid.IcsImport.Cutoff do
  @moduledoc """
  Narrows an `.ics` import to the events that still matter from a date on,
  and sums up a file holding more events than one import writes, so the
  organiser can choose that date. Part of `Tymeslot.CalendarGrid.IcsImport`.

  The cutoff is the start of its date in the organiser's zone. An event is
  kept when it ends after that, so one running across midnight into the
  cutoff's day stays. A series is kept when any of its occurrences may end
  after it: its `UNTIL` or `COUNT` is read as the series' end, and one with
  neither never ends. A series that started years ago and still repeats is
  the organiser's live meeting, however old its first start. A rule that
  cannot be read, one with parts the expander does not follow, or a `COUNT`
  whose end `RecurrenceExpander.last_start/2` will not work out, is kept:
  importing a series that has ended costs less than losing one that has not.
  Each event's end is worked out once, whichever cutoffs it is compared with.

  The events judged are the writes `IcsImport.Series` has already resolved,
  never the file's VEVENTs one by one. A series' exclusions come from every
  override in the file, and an occurrence an override moved is judged at its
  new time, as the event of its own it is written as; an override is never
  kept apart from the series it changes.
  """

  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.DateTimeUtils

  @utc "Etc/UTC"
  # The cutoffs offered, in months before today, earliest first.
  @suggested_months [12, 6, 3, 0]

  @type suggestion :: %{from: Date.t(), events: non_neg_integer(), importable: boolean()}

  @type overview :: %{
          events: non_neg_integer(),
          series: non_neg_integer(),
          first: Date.t(),
          last: Date.t(),
          suggestions: [suggestion()]
        }

  @doc """
  The events of `events` kept from `from` on, read in `zone`, and how many
  were left out. With no `from`, every event is kept.
  """
  @spec narrow([map()], Date.t() | nil, String.t()) :: {[map()], non_neg_integer()}
  def narrow(events, nil, _zone), do: {events, 0}

  def narrow(events, %Date{} = from, zone) do
    cutoff = cutoff(from, zone)
    kept = Enum.filter(events, &(&1 |> last_end() |> reaches?(cutoff)))
    {kept, length(events) - length(kept)}
  end

  @doc """
  What a file too large to import whole holds: its events (`:series` of
  them repeating), the days the first and last of them start on in `zone`,
  and how many each suggested cutoff (today, and 3, 6 and 12 months before)
  would keep. A suggestion is `:importable` when it keeps at least one event
  and no more than `max`.
  """
  @spec overview([map(), ...], String.t(), pos_integer()) :: overview()
  def overview(events, zone, max) do
    today = zone |> DateTimeUtils.now_in_timezone() |> DateTime.to_date()
    {first, last} = events |> Enum.map(&start_date(&1, zone)) |> Enum.min_max_by(& &1, Date)
    ends = Enum.map(events, &last_end/1)

    suggestions =
      for months <- @suggested_months do
        from = Date.shift(today, month: -months)
        cutoff = cutoff(from, zone)
        count = Enum.count(ends, &reaches?(&1, cutoff))
        %{from: from, events: count, importable: count in 1..max//1}
      end

    %{
      events: length(events),
      series: Enum.count(events, &Map.has_key?(&1, :recurrence_rule)),
      first: first,
      last: last,
      suggestions: suggestions
    }
  end

  # --- Keeping an event ---

  defp cutoff(from, zone) do
    instant =
      case DateTime.new(from, ~T[00:00:00], zone) do
        {:ok, at} -> at
        {:ambiguous, first, _second} -> first
        {:gap, _before, just_after} -> just_after
        {:error, _reason} -> DateTime.new!(from, ~T[00:00:00], @utc)
      end

    %{date: from, instant: DateTime.shift_zone!(instant, @utc)}
  end

  # When an event's last occurrence ends, whatever the cutoff; `:never` for a
  # series without an end that can be read.
  defp last_end(%{recurrence_rule: rule} = event) do
    case RRule.parse(rule) do
      {:ok, %RRule{other: [], count: count}} when is_integer(count) ->
        count_end(event, rule)

      {:ok, %RRule{other: [], until: until} = parsed} when is_binary(until) ->
        until_end(event, parsed)

      _unbounded_or_unreadable ->
        :never
    end
  end

  defp last_end(event), do: event.end_time

  defp reaches?(:never, _cutoff), do: true
  # An all-day event's end is the day after its last.
  defp reaches?(%Date{} = end_date, cutoff), do: Date.after?(end_date, cutoff.date)
  defp reaches?(%DateTime{} = end_at, cutoff), do: DateTime.after?(end_at, cutoff.instant)

  defp count_end(%{start_time: %Date{} = first} = event, rule) do
    case RecurrenceExpander.last_start(rule, first) do
      {:ok, last_day} -> Date.add(last_day, days(event))
      :unknown -> :never
    end
  end

  defp count_end(%{start_time: %DateTime{} = start} = event, rule) do
    case RecurrenceExpander.last_start(rule, DateTime.shift_zone!(start, series_zone(event))) do
      {:ok, last_start} -> DateTime.add(last_start, seconds(event))
      :unknown -> :never
    end
  end

  defp until_end(event, parsed) do
    zone = series_zone(event)

    case {RRule.until_instant(parsed, zone), event.start_time} do
      {nil, _start} ->
        :never

      {last_start, %Date{}} ->
        last_day = last_start |> DateTime.shift_zone!(zone) |> DateTime.to_date()
        Date.add(last_day, days(event))

      {last_start, %DateTime{}} ->
        DateTime.add(last_start, seconds(event))
    end
  end

  defp days(event), do: Date.diff(event.end_time, event.start_time)
  defp seconds(event), do: DateTime.diff(event.end_time, event.start_time)

  defp series_zone(event) do
    zone = event[:timezone]
    if is_binary(zone) and Timezones.valid?(zone), do: zone, else: @utc
  end

  defp start_date(%{start_time: %Date{} = date}, _zone), do: date

  defp start_date(%{start_time: %DateTime{} = at}, zone),
    do: at |> DateTime.shift_zone!(zone) |> DateTime.to_date()
end
