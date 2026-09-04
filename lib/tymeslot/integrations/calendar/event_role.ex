defmodule Tymeslot.Integrations.Calendar.EventRole do
  @moduledoc """
  The vocabulary of the `role` column on cached calendar events.

  `role` says which read path owns a cached row, and therefore which reads may
  return it at all:

    * `both` — blocks availability and appears on the dashboard grid. Every
      provider but Exchange, and the column's default, so every row written
      before the column existed carries it.
    * `display_only` — appears on the grid, blocks nothing. Exchange's item
      path writes these: a recurring master's dates describe only its own
      first occurrence, so blocking on them would free up every later one.
    * `busy_only` — blocks availability, never shown. Exchange's
      `GetUserAvailability` read writes these; they carry no identity worth
      rendering.

  It composes with `transparency` and `status` rather than replacing them, and
  neither side overrides the other. `role` is a **query-level** filter, applied
  in `CalendarEventQueries.in_range/2` and
  `ProviderCalendarEventQueries.list_for_range/4`; `transparency` and `status`
  are **row-level**, and `CalendarEvent.blocking?/1` — the one function the
  whole availability calculation routes through — reads those two and never
  this one. A `busy_only` row that is not opaque therefore blocks nothing.

  It exists as a module rather than as literals spelled at each site because a
  mistyped literal compiles fine and silently never matches, and the two
  failure modes that buys are a mailbox reported as free and a nameless block
  drawn on someone's calendar. It carries no dependencies of its own so that
  referring to it at compile time costs nothing.
  """

  @both "both"
  @display_only "display_only"
  @busy_only "busy_only"
  @all [@both, @display_only, @busy_only]

  @doc "Blocks availability and appears on the grid. The default."
  @spec both() :: String.t()
  def both, do: @both

  @doc "Appears on the grid, blocks nothing."
  @spec display_only() :: String.t()
  def display_only, do: @display_only

  @doc "Blocks availability, never shown."
  @spec busy_only() :: String.t()
  def busy_only, do: @busy_only

  @doc "Every value the column's check constraint admits."
  @spec all() :: [String.t()]
  def all, do: @all
end
