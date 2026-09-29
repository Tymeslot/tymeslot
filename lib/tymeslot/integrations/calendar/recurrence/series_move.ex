defmodule Tymeslot.Integrations.Calendar.Recurrence.SeriesMove do
  @moduledoc """
  How far a Google or Outlook series moves when one of its occurrences is
  edited for every occurrence.

  Both providers keep a series as a master event whose start and end the
  occurrences repeat, so an edit of all of them from one occurrence is a
  move of the master: by as much as the edited occurrence moved from where
  it shows now, on the wall clock of the master's own zone, so a series
  moved from 10:00 to 11:00 in Berlin reads 11:00 on both sides of a DST
  change. A change of how long the occurrence lasts gives the master that
  duration; otherwise the master keeps its own. An all-day series moves by
  whole days.

  The CalDAV equivalent is `ICalBuilder.Series.edit_master/5`, which works on
  the iCalendar lines the series is stored in; this works on the master's
  timing once each provider has read it.
  """

  @day 86_400

  @typedoc """
  The edit of one occurrence: where it shows now (`:start`, `:end`) and the
  payload fields it is being given (`:changes`, whose `:start_time` and
  `:end_time` are where it is going).
  """
  @type edit :: %{
          required(:start) => Date.t() | DateTime.t(),
          required(:end) => Date.t() | DateTime.t(),
          required(:changes) => map(),
          optional(atom()) => term()
        }

  @typedoc """
  A master's start and end: whole days, or wall clocks in its zone.
  """
  @type timing :: {Date.t(), Date.t()} | {NaiveDateTime.t(), NaiveDateTime.t()}

  @typedoc """
  The master's new timing, how far it moved (seconds on its wall clock), and
  by how many dates its start moved.
  """
  @type move :: %{
          start: Date.t() | NaiveDateTime.t(),
          end: Date.t() | NaiveDateTime.t(),
          shift: integer(),
          days: integer()
        }

  @doc """
  Whether `edit` moves the occurrence or changes how long it lasts.
  """
  @spec moved?(edit()) :: boolean()
  def moved?(%{changes: %{start_time: start, end_time: finish}} = edit)
      when is_struct(start) and is_struct(finish),
      do: not (same?(start, edit.start) and same?(finish, edit.end))

  def moved?(_edit), do: false

  @doc """
  The master's new timing for `edit`, from its current `timing`, on the wall
  clock of `zone` (an IANA name; ignored for an all-day series).

  Returns `{:ok, :unmoved}` when the edit leaves the occurrence where it is,
  `{:ok, move}`, `{:error, :value_type_change}` when the edit turns a timed
  series all-day or back, or `{:error, :unreadable_timing}` when a timed
  series has no zone this can read.
  """
  @spec move(edit(), timing(), String.t() | nil) ::
          {:ok, :unmoved | move()} | {:error, :value_type_change | :unreadable_timing}
  def move(edit, timing, zone) do
    if moved?(edit), do: plan(edit, timing, zone), else: {:ok, :unmoved}
  end

  defp plan(
         %{changes: %{start_time: %Date{} = to, end_time: %Date{} = until}} = edit,
         timing,
         _zone
       ) do
    case {edit.start, timing} do
      {%Date{} = from, {%Date{} = master_start, %Date{} = master_end}} ->
        days = Date.diff(to, from)
        wanted = Date.diff(until, to)
        new_start = Date.add(master_start, days)

        new_end =
          if wanted == Date.diff(edit.end, from),
            do: Date.add(master_end, days),
            else: Date.add(new_start, wanted)

        {:ok, %{start: new_start, end: new_end, shift: days * @day, days: days}}

      _timed ->
        {:error, :value_type_change}
    end
  end

  defp plan(%{changes: %{start_time: %DateTime{}}}, _timing, nil),
    do: {:error, :unreadable_timing}

  defp plan(%{changes: %{start_time: %DateTime{} = to, end_time: until}} = edit, timing, zone) do
    with {%NaiveDateTime{} = master_start, %NaiveDateTime{} = master_end} <- timing,
         %DateTime{} <- edit.start,
         {:ok, from} <- wall(edit.start, zone),
         {:ok, to} <- wall(to, zone),
         {:ok, current_end} <- wall(edit.end, zone),
         {:ok, until} <- wall(until, zone) do
      shift = NaiveDateTime.diff(to, from)
      wanted = NaiveDateTime.diff(until, to)
      new_start = NaiveDateTime.add(master_start, shift)

      new_end =
        if wanted == NaiveDateTime.diff(current_end, from),
          do: NaiveDateTime.add(master_end, shift),
          else: NaiveDateTime.add(new_start, wanted)

      days = Date.diff(NaiveDateTime.to_date(new_start), NaiveDateTime.to_date(master_start))
      {:ok, %{start: new_start, end: new_end, shift: shift, days: days}}
    else
      :error -> {:error, :unreadable_timing}
      _mixed -> {:error, :value_type_change}
    end
  end

  defp plan(_edit, _timing, _zone), do: {:error, :value_type_change}

  defp wall(%DateTime{} = instant, zone) do
    case DateTime.shift_zone(instant, zone) do
      {:ok, local} -> {:ok, local |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)}
      {:error, _reason} -> :error
    end
  end

  defp wall(_not_an_instant, _zone), do: :error

  defp same?(%Date{} = left, %Date{} = right), do: Date.compare(left, right) == :eq

  defp same?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same?(_left, _right), do: false
end
