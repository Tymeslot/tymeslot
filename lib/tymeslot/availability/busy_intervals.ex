defmodule Tymeslot.Availability.BusyIntervals do
  @moduledoc """
  The busy periods the slot engine works from, as the UTC instants they block.

  Each blocking period goes through `Tymeslot.Availability.Events.to_interval/2`,
  the one conversion every consumer of calendar events shares, so an all-day
  event (a date, a `CalendarEvent` struct, or the UTC-midnight pair some CalDAV
  servers emit) covers the same stretch as it does on the booking page. A period
  that cannot be converted is dropped.
  """

  alias Tymeslot.Availability.Events
  alias Tymeslot.Integrations.Calendar.CalendarEvent

  @typedoc "What `Tymeslot.Availability.Offer.slots_and_busy_for_range/4` answers."
  @type range_view :: %{
          slots: %{String.t() => [term()]},
          starts: %{String.t() => [DateTime.t()]},
          busy: [{DateTime.t(), DateTime.t()}],
          windows: [Tymeslot.Availability.BusinessHours.owner_window()]
        }

  @doc "The blocking `periods` as UTC `{start, end}` instants."
  @spec of([CalendarEvent.t() | map()], String.t()) :: [{DateTime.t(), DateTime.t()}]
  def of(periods, owner_timezone) do
    for period <- periods,
        CalendarEvent.blocking?(period),
        {:ok, interval} <- [Events.to_interval(period, owner_timezone)],
        do: interval
  end
end
