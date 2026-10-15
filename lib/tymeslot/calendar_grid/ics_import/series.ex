defmodule Tymeslot.CalendarGrid.IcsImport.Series do
  @moduledoc """
  Works out what an `.ics` import writes for each recurring series in a file,
  given the overrides that change it. Part of `Tymeslot.CalendarGrid.IcsImport`.

  An override (a VEVENT with a `RECURRENCE-ID`) replaces one occurrence of
  the series sharing its UID, its *slot*. When that series is in the file:

    * a moved occurrence is excluded from the series and written as an event
      of its own; a cancelled one is only excluded,
    * an override with `RANGE=THISANDFUTURE` replaces its slot and every
      later occurrence, so the series is split there: the original ends just
      before the slot, and the override is written as the rest of the series,
      repeating by its own rule or else by the original's from its new start.
      The exclusions after the slot move with it. Cancelling "this and
      future" ends the series before the slot.

  An override whose series is not in the file has nothing to replace and is
  written on its own. So is one whose slot cannot be read at all, which can
  then show beside the occurrence it was meant to replace; every form RFC
  5545 allows is read.

  Each result is a `{raw_event, rule, exclusions}` to write, with the
  exclusions in the value type of the event's start: dates for an all-day
  series, UTC instants for a timed one.
  """

  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander
  alias Tymeslot.Timezones

  @utc "Etc/UTC"

  @type slot :: Date.t() | DateTime.t()
  @type write :: {map(), String.t() | nil, [slot()]}

  @doc """
  The writes for the `live` events of a file, given its `cancelled` ones,
  whose overrides only ever exclude.
  """
  @spec resolve([map()], [map()]) :: [write()]
  def resolve(live, cancelled) do
    masters = for raw <- live, series?(raw), not override?(raw), into: %{}, do: {raw.uid, raw}
    plans = plans(masters, live, cancelled)
    consumed = plans |> Map.values() |> Enum.flat_map(& &1.consumed) |> MapSet.new()

    Enum.flat_map(live, fn raw ->
      cond do
        MapSet.member?(consumed, raw) -> []
        masters[raw.uid] == raw -> master_writes(raw, plans)
        true -> [{raw, nil, []}]
      end
    end)
  end

  # Each series' plan, from the overrides whose slot in it can be read.
  defp plans(masters, live, cancelled) do
    tagged = Enum.map(live, &{&1, true}) ++ Enum.map(cancelled, &{&1, false})

    for {raw, live?} <- tagged,
        override?(raw),
        master = masters[raw.uid],
        slot = slot(raw, master) do
      %{raw: raw, live?: live?, slot: slot}
    end
    |> Enum.group_by(& &1.raw.uid)
    |> Map.new(fn {uid, of_series} -> {uid, plan(masters[uid], of_series)} end)
  end

  defp master_writes(master, plans) do
    case plans[master.uid] do
      nil -> [{master, master.recurrence_rule, exclusions(master, [])}]
      plan -> plan.writes
    end
  end

  # --- Planning one series ---

  defp plan(master, overrides) do
    {futures, singles} = Enum.split_with(overrides, &future?/1)

    case futures |> Enum.sort_by(& &1.slot, slot_order(master)) |> split_point(master) do
      {split, delta, tail_rule} ->
        # A later "this and future" is read as moving its own slot only.
        singles = singles ++ Enum.reject(futures, &(&1 == split))
        split(master, split, delta, tail_rule, exclusions(master, singles))

      nil ->
        %{
          writes: [{master, master.recurrence_rule, exclusions(master, overrides)}],
          consumed: []
        }
    end
  end

  # The earliest "this and future" the series can be split at: one whose new
  # start shares the series' value type, and whose rest can be counted.
  defp split_point(futures, master) do
    Enum.find_value(futures, fn future ->
      with delta when is_integer(delta) <- delta(future.slot, future.raw.start_time),
           {:ok, rule} <- tail_rule(future, master) do
        {future, delta, rule}
      else
        _cannot_split -> nil
      end
    end)
  end

  defp split(master, future, delta, tail_rule, exclusions) do
    {before, from} = Enum.split_with(exclusions, &before?(&1, future.slot))

    head =
      if before?(master.start_time, future.slot),
        do: [{master, RRule.end_before(master.recurrence_rule, future.slot), before}],
        else: []

    tail =
      if future.live?,
        do: [{future.raw, tail_rule, tail_exclusions(future.raw, from, delta)}],
        else: []

    %{writes: head ++ tail, consumed: [future.raw]}
  end

  # The original's exclusions from the slot on, moved as far as the override
  # moved its slot, and any of the override's own.
  defp tail_exclusions(raw, from, delta) do
    own = Enum.map(raw[:exdates] || [], &in_type(&1, raw))

    (Enum.map(from, &shift(&1, delta)) ++ own)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # The override's own rule, or the original's with the occurrences before
  # the slot taken off its COUNT. A COUNT over parts the count cannot follow
  # is not split, rather than ending the series on another date.
  defp tail_rule(%{raw: raw} = future, master) do
    rule = master.recurrence_rule

    cond do
      series?(raw) ->
        {:ok, raw.recurrence_rule}

      not Map.has_key?(RRule.parse(rule), :count) ->
        {:ok, rule}

      RecurrenceExpander.countable?(rule) ->
        {:ok, RRule.reduce_count(rule, count_before(master, future.slot))}

      true ->
        :error
    end
  end

  defp count_before(master, slot) do
    first =
      case master.start_time do
        %Date{} = date -> date
        %DateTime{} = at -> DateTime.shift_zone!(at, zone(master))
      end

    RecurrenceExpander.count_before(master.recurrence_rule, first, slot)
  end

  defp exclusions(master, overrides) do
    (master[:exdates] || [])
    |> Enum.map(&in_type(&1, master))
    |> Enum.concat(Enum.map(overrides, & &1.slot))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # --- Slots ---

  # A RECURRENCE-ID with a TZID comes resolved from the parser; the rest are
  # read here, a wall clock in the series' own zone.
  defp slot(raw, master) do
    value = raw[:recurrence_id_at] || read_recurrence_id(raw.recurrence_id, master)
    value && in_type(value, master)
  end

  @recurrence_id ~r/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?$/

  defp read_recurrence_id(value, master) do
    case Regex.run(@recurrence_id, String.trim(value)) do
      [_all, y, m, d] ->
        date(y, m, d)

      [_all, y, m, d, hh, mm, ss, "Z"] ->
        instant([y, m, d, hh, mm, ss], @utc)

      [_all, y, m, d, hh, mm, ss, ""] ->
        instant([y, m, d, hh, mm, ss], zone(master))

      _unreadable ->
        nil
    end
  end

  defp date(y, m, d) do
    case Date.new(to_int(y), to_int(m), to_int(d)) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp instant([y, m, d, hh, mm, ss], zone) do
    case NaiveDateTime.new(to_int(y), to_int(m), to_int(d), to_int(hh), to_int(mm), to_int(ss)) do
      {:ok, naive} -> at_wall_clock(naive, zone)
      {:error, _reason} -> nil
    end
  end

  # RFC 5545 §3.3.5: a wall clock a DST change repeats means its first
  # instant, and one it skips means the instant just after the gap.
  defp at_wall_clock(naive, zone) do
    case DateTime.from_naive(naive, zone) do
      {:ok, local} -> DateTime.shift_zone!(local, @utc)
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, @utc)
      {:gap, _before, just_after} -> DateTime.shift_zone!(just_after, @utc)
      {:error, _reason} -> nil
    end
  end

  # A slot in the value type of the series' start: the day an instant falls
  # on for an all-day series, and for a timed one the series' time of day on
  # a bare date.
  defp in_type(%DateTime{} = at, %{start_time: %Date{}} = master),
    do: at |> DateTime.shift_zone!(zone(master)) |> DateTime.to_date()

  defp in_type(%Date{} = date, %{start_time: %DateTime{} = start} = master) do
    time = start |> DateTime.shift_zone!(zone(master)) |> DateTime.to_time()
    at_wall_clock(NaiveDateTime.new!(date, time), zone(master))
  end

  defp in_type(slot, _master), do: slot

  # --- Helpers ---

  defp zone(master) do
    zone = master[:timezone]
    if is_binary(zone) and Timezones.valid?(zone), do: zone, else: @utc
  end

  defp delta(%Date{} = slot, %Date{} = start), do: Date.diff(start, slot)
  defp delta(%DateTime{} = slot, %DateTime{} = start), do: DateTime.diff(start, slot)
  defp delta(_slot, _start), do: nil

  defp shift(%Date{} = date, days), do: Date.add(date, days)
  defp shift(%DateTime{} = at, seconds), do: DateTime.add(at, seconds)

  defp before?(%Date{} = a, %Date{} = b), do: Date.before?(a, b)
  defp before?(%DateTime{} = a, %DateTime{} = b), do: DateTime.before?(a, b)

  defp slot_order(%{start_time: %Date{}}), do: Date
  defp slot_order(_master), do: DateTime

  defp future?(override), do: override.raw[:recurrence_id_range] == :this_and_future

  defp override?(raw), do: is_binary(raw[:recurrence_id]) and raw[:recurrence_id] != ""

  defp series?(raw), do: is_binary(raw[:recurrence_rule]) and raw[:recurrence_rule] != ""

  defp to_int(digits), do: String.to_integer(digits)
end
