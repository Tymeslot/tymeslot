defmodule Tymeslot.Integrations.Calendar.Recurrence.SplitExceptions do
  @moduledoc """
  Carrying a Google or Outlook series' occurrences edited or cancelled on
  their own across a split (see `Recurrence.SeriesSplit`): what both
  providers share. `Google.SeriesExceptions` and `Outlook.SeriesExceptions`
  read each provider's exceptions into `t:exception/0` and write the tail's
  matching occurrences.

  Both providers keep such an occurrence apart from the master's rule, and
  drop it once the master is ended before it, so the tail, a new series,
  starts without it. Each one from the split's slot on is read before the
  split is written, and then written again to the tail's occurrence that
  takes its place: the one whose original start is the exception's, moved
  by as much as the edit moved the series. A cancelled occurrence is
  cancelled there; an edited one takes what it had of its own:

    * **fields** that differ from the master's as it was before the edit,
      so an occurrence renamed on its own keeps its name while the rest of
      the tail takes the edit's;
    * **timing**, when it was moved or given another length on its own. It
      moves with the series, and keeps its own length unless it lasted as
      long as the series did, when it takes the series' new length, as a
      CalDAV override does (`ICalBuilder.Series.edit_master/5`).

  An exception whose place the tail does not have, because the edit gave
  the series a new rule, cannot be carried. The split is written by then,
  so neither that nor a failed write fails it: `carry/2` counts and logs
  them.
  """

  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesMove

  require Logger

  @day 86_400

  @typedoc "A slot or timing on the series' wall clock: a day, or a wall clock in its zone."
  @type wall :: Date.t() | NaiveDateTime.t()

  @typedoc """
  What an occurrence had of its own: cancelled, or the provider's fields it
  changed and its timing (`nil` when it is where the series puts it).
  """
  @type change :: :cancelled | {:edited, map(), {wall(), wall()} | nil}

  @typedoc """
  An occurrence as the provider holds it apart from the master: its slot,
  and whether it was cancelled or edited, with its fields that differ from
  the master's and its own timing.
  """
  @type exception :: %{slot: wall(), change: :cancelled | {:edited, map(), {wall(), wall()}}}

  @typedoc "The tail's occurrence an exception is written to, by its original start."
  @type carry :: %{target: wall(), change: change()}

  @typedoc "How writing one carry went."
  @type outcome :: :ok | :unmatched | {:error, term()}

  @doc """
  The carries for `exceptions` of a series whose master's timing is
  `timing` (see `Recurrence.SeriesMove.timing/0`), split at `slot` (on the
  same wall clock) by an edit that moves it as `move` says (see
  `Recurrence.SeriesMove.move/3`). Exceptions before the slot stay with the
  head; an edited one with nothing of its own left is not carried.
  """
  @spec plan([exception()], wall(), SeriesMove.timing(), :unmoved | SeriesMove.move()) ::
          [carry()]
  def plan(exceptions, slot, {start, finish}, move) do
    lengths = %{series: length_of(start, finish), tail: tail_length(move, start, finish)}
    shift = if move == :unmoved, do: 0, else: move.shift

    exceptions
    |> Enum.filter(&same_type?(&1.slot, slot))
    |> Enum.reject(&before?(&1.slot, slot))
    |> Enum.map(fn %{slot: from, change: change} ->
      %{target: later(from, shift), change: carried(change, from, lengths, shift)}
    end)
    |> Enum.reject(&(&1.change == {:edited, %{}, nil}))
  end

  defp tail_length(:unmoved, start, finish), do: length_of(start, finish)
  defp tail_length(%{start: start, end: finish}, _start, _finish), do: length_of(start, finish)

  defp carried(:cancelled, _slot, _lengths, _shift), do: :cancelled

  defp carried({:edited, fields, {start, finish}}, slot, lengths, shift) do
    own = length_of(start, finish)

    timing =
      if same?(start, slot) and own == lengths.series do
        nil
      else
        moved = later(start, shift)
        {moved, later(moved, if(own == lengths.series, do: lengths.tail, else: own))}
      end

    {:edited, fields, timing}
  end

  @doc """
  Writes each of `carries` with `write`, which answers `:ok`, `:unmatched`
  when the tail has no occurrence at the target, or an error. The split is
  already written, so nothing here fails it: a write that raises counts as
  failed, and what could not be carried is logged. Answers the counts.
  """
  @spec carry([carry()], (carry() -> outcome())) :: %{
          carried: non_neg_integer(),
          unmatched: non_neg_integer(),
          failed: non_neg_integer()
        }
  def carry(carries, write) do
    {counts, reasons} =
      Enum.reduce(carries, {%{carried: 0, unmatched: 0, failed: 0}, []}, fn carry, acc ->
        tally(acc, safely(write, carry))
      end)

    log(counts, reasons)
    counts
  end

  defp safely(write, carry) do
    write.(carry)
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp tally({counts, reasons}, :ok), do: {Map.update!(counts, :carried, &(&1 + 1)), reasons}

  defp tally({counts, reasons}, :unmatched),
    do: {Map.update!(counts, :unmatched, &(&1 + 1)), reasons}

  defp tally({counts, reasons}, error),
    do: {Map.update!(counts, :failed, &(&1 + 1)), [error | reasons]}

  defp log(%{failed: 0, unmatched: 0}, _reasons), do: :ok

  defp log(counts, reasons) do
    Logger.warning(
      "Could not carry every occurrence changed on its own to the new half of a split series",
      carried: counts.carried,
      unmatched: counts.unmatched,
      failed: counts.failed,
      reasons: inspect(Enum.reverse(reasons))
    )
  end

  # --- Walls ---

  defp same_type?(%Date{}, %Date{}), do: true
  defp same_type?(%NaiveDateTime{}, %NaiveDateTime{}), do: true
  defp same_type?(_left, _right), do: false

  defp before?(%Date{} = left, right), do: Date.compare(left, right) == :lt
  defp before?(left, right), do: NaiveDateTime.compare(left, right) == :lt

  defp same?(%Date{} = left, %Date{} = right), do: Date.compare(left, right) == :eq

  defp same?(%NaiveDateTime{} = left, %NaiveDateTime{} = right),
    do: NaiveDateTime.compare(left, right) == :eq

  defp same?(_left, _right), do: false

  # Seconds on the wall clock, whole days for an all-day series.
  defp length_of(%Date{} = start, %Date{} = finish), do: Date.diff(finish, start) * @day
  defp length_of(start, finish), do: NaiveDateTime.diff(finish, start)

  defp later(wall, seconds) do
    case wall do
      %Date{} -> Date.add(wall, div(seconds, @day))
      _timed -> NaiveDateTime.add(wall, seconds)
    end
  end
end
