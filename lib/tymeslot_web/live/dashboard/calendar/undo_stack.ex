defmodule TymeslotWeb.Dashboard.Calendar.UndoStack do
  @moduledoc """
  The changes the organiser can take back on the calendar surface, newest
  first. An entry is a map whose `:kind` says how to undo it (see
  `Manipulation.undo/1`): `:timing` for a move or resize, `:delete` for a
  delete still inside its undo window. Entries that can no longer be undone
  (a write that failed, a delete that has run) are dropped with `drop/2`.
  """

  @limit 20

  @type entry :: map()
  @type t :: [entry()]

  @doc "An empty stack."
  @spec new() :: t()
  def new, do: []

  @doc "How many changes the stack keeps."
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc "Adds `entry` as the newest change, forgetting the oldest past the limit."
  @spec push(t(), entry()) :: t()
  def push(stack, entry), do: Enum.take([entry | stack], @limit)

  @doc "The newest change and the stack without it; `nil` when there is none."
  @spec pop(t()) :: {entry() | nil, t()}
  def pop([]), do: {nil, []}
  def pop([entry | rest]), do: {entry, rest}

  @doc "Removes every entry `fun` answers true for."
  @spec drop(t(), (entry() -> boolean())) :: t()
  def drop(stack, fun), do: Enum.reject(stack, fun)
end
