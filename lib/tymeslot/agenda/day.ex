defmodule Tymeslot.Agenda.Day do
  @moduledoc """
  The assembled dashboard agenda for a user.

  * `next` — the single next *timed* appointment, surfaced as the hero. May fall
    beyond tomorrow (in which case `later?` is true) so the hero is never empty
    while anything is upcoming. All-day entries are never the hero.
  * `today` / `tomorrow` — the remaining entries for each day, in start order,
    with the hero excluded so it is never shown twice.
  * `has_calendar?` — whether the user has any active calendar integration; drives
    the "connect a calendar" nudge.
  * `later?` — whether `next` falls after tomorrow, so the view can frame the hero
    as the next thing on the horizon rather than an imminent one.
  * `timezone` — the (normalised) timezone the agenda was bucketed in, carried so
    the view formats times against the exact zone the grouping used.
  """

  alias Tymeslot.Agenda.Entry

  defstruct next: nil,
            today: [],
            tomorrow: [],
            has_calendar?: false,
            later?: false,
            timezone: "Etc/UTC"

  @type t :: %__MODULE__{
          next: Entry.t() | nil,
          today: [Entry.t()],
          tomorrow: [Entry.t()],
          has_calendar?: boolean(),
          later?: boolean(),
          timezone: String.t()
        }

  @doc "True when there is nothing at all to show — no hero and no grouped entries."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{next: nil, today: [], tomorrow: []}), do: true
  def empty?(%__MODULE__{}), do: false
end
