defmodule Tymeslot.BookingSeries.Notifications do
  @moduledoc """
  The emails a booking series sends as one, rather than per occurrence.

  Placeholder: the series confirmation is not built yet, so a series is
  booked without one. Each occurrence still schedules its own reminders
  (`Tymeslot.Bookings.Activation`, `announce: :series`). The series
  confirmation email replaces this stub.
  """

  alias Tymeslot.BookingSeries.SeriesSchema

  @doc """
  Schedules the one confirmation a newly booked series sends its booker and
  host. Called in the transaction that books the series, so it commits with
  the series or not at all.

  Not implemented yet: returns `{:ok, :not_implemented}` and schedules
  nothing.
  """
  @spec schedule_series_confirmation(SeriesSchema.t()) :: {:ok, :not_implemented}
  def schedule_series_confirmation(%SeriesSchema{}), do: {:ok, :not_implemented}
end
