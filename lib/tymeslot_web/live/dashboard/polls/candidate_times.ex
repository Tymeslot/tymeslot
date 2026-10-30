defmodule TymeslotWeb.Dashboard.Polls.CandidateTimes do
  @moduledoc """
  The rows of candidate-time inputs the poll forms keep: the create form's
  times (`PollForm`) and the times an edit adds (`PollEditor`).

  Each row is `%{key: integer, value: string}`. The key comes from a counter
  the form owns and is never reused, so a row keeps its input (and the
  `datetime-local` value the browser holds in it) when one before it is
  removed. Change events carry the values keyed by the key as a string.
  """

  @type row :: %{key: non_neg_integer(), value: String.t()}

  @doc "Appends a row with `value` under `counter`, and returns the next counter."
  @spec add([row()], non_neg_integer(), String.t()) :: {[row()], non_neg_integer()}
  def add(rows, counter, value \\ ""), do: {rows ++ [%{key: counter, value: value}], counter + 1}

  @doc """
  Removes the row under `key`, as a remove button sends it, and returns the
  key read. A key that is not a whole number was forged and is `:error`.
  """
  @spec remove([row()], String.t()) :: {:ok, [row()], integer()} | :error
  def remove(rows, key) do
    case Integer.parse(key) do
      {key, ""} -> {:ok, Enum.reject(rows, &(&1.key == key)), key}
      _forged -> :error
    end
  end

  @doc """
  Takes each row's value from a change event's `values`, keeping a row's
  value when the event does not carry it.
  """
  @spec merge([row()], %{optional(String.t()) => String.t()}) :: [row()]
  def merge(rows, values) do
    Enum.map(rows, fn %{key: key} = row ->
      %{row | value: Map.get(values, Integer.to_string(key), row.value)}
    end)
  end
end
