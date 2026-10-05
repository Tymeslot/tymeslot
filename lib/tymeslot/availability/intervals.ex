defmodule Tymeslot.Availability.Intervals do
  @moduledoc """
  Half-open `{from, to}` intervals of instants, and the four operations the
  slot engine needs on them.

  Comparisons are by instant (`DateTime.compare/2`), so intervals resolved in
  different zones mix freely. Intervals that touch are joined: consecutive
  24-hour windows form one stretch, which is how a meeting runs from one day's
  hours into the next.
  """

  @type t :: {DateTime.t(), DateTime.t()}

  @doc "Sorted, disjoint intervals covering the same time; empty intervals are dropped."
  @spec merge([t()]) :: [t()]
  def merge(intervals) do
    intervals
    |> Enum.filter(&non_empty?/1)
    |> Enum.sort_by(&elem(&1, 0), DateTime)
    |> Enum.reduce([], fn
      {from, to}, [{prev_from, prev_to} | rest] = acc ->
        if DateTime.compare(from, prev_to) != :gt,
          do: [{prev_from, latest(prev_to, to)} | rest],
          else: [{from, to} | acc]

      interval, [] ->
        [interval]
    end)
    |> Enum.reverse()
  end

  @doc "`free` with every instant inside `blocked` removed."
  @spec subtract([t()], [t()]) :: [t()]
  def subtract(free, blocked) do
    blocked = merge(blocked)
    free |> merge() |> Enum.flat_map(&cut(&1, blocked))
  end

  @doc "The parts of `intervals` inside `bounds`."
  @spec clip([t()], t()) :: [t()]
  def clip(intervals, {lower, upper}) do
    intervals
    |> Enum.map(fn {from, to} -> {latest(from, lower), earliest(to, upper)} end)
    |> Enum.filter(&non_empty?/1)
  end

  @doc "Whether one interval holds all of `from..to`."
  @spec covers?([t()], DateTime.t(), DateTime.t()) :: boolean()
  def covers?(intervals, from, to) do
    Enum.any?(intervals, fn {free_from, free_to} ->
      DateTime.compare(free_from, from) != :gt and DateTime.compare(to, free_to) != :gt
    end)
  end

  # `blocked` is merged, so sorted: a block ending at or before the interval is
  # skipped, one starting at or after its end ends the cut.
  defp cut(interval, []), do: [interval]

  defp cut({from, to} = interval, [{block_from, block_to} | rest]) do
    cond do
      DateTime.compare(block_to, from) != :gt ->
        cut(interval, rest)

      DateTime.compare(block_from, to) != :lt ->
        [interval]

      true ->
        before = if DateTime.compare(block_from, from) == :gt, do: [{from, block_from}], else: []

        after_block =
          if DateTime.compare(block_to, to) == :lt, do: cut({block_to, to}, rest), else: []

        before ++ after_block
    end
  end

  defp non_empty?({from, to}), do: DateTime.compare(from, to) == :lt

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
end
