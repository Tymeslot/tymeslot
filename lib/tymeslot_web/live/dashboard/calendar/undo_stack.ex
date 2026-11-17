defmodule TymeslotWeb.Dashboard.Calendar.UndoStack do
  @moduledoc """
  The changes the organiser can take back on the calendar surface, newest
  first. An entry is a map whose `:kind` says how to undo it (see
  `Manipulation.undo/1`): `:timing` for a move or resize, `:edit` for a
  change made in the side panel (`PanelEdits.undo/2`), `:delete` for a
  delete still inside its undo window, `:create` for an event just created
  (undone by removing it, see `Creation.undo/2`), `:opening` for bookable
  times opened from quick create (undone by restoring the old hours, see
  `OpenBooking.undo/2`), `:gone` for a delete that
  has since run (Ctrl Z on it only says it is too late, so it does not reach
  an older change by mistake). Entries that can no longer be undone (a write
  that failed) are dropped with `drop/2`.
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

  @doc "Applies `fun` to every entry, keeping its place."
  @spec map(t(), (entry() -> entry())) :: t()
  def map(stack, fun), do: Enum.map(stack, fun)

  @doc "Replaces every entry `fun` answers true for with `entry`, keeping its place."
  @spec replace(t(), (entry() -> boolean()), entry()) :: t()
  def replace(stack, fun, entry),
    do: Enum.map(stack, fn existing -> if fun.(existing), do: entry, else: existing end)
end
