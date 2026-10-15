defmodule Tymeslot.Bookings.Telemetry do
  @moduledoc """
  Telemetry events emitted by the booking domain.

  Shared by `Tymeslot.Bookings.Create` and `Tymeslot.Bookings.CreateGroup` so
  neither has to reach into the other to report a completed booking.
  """

  @doc "Emits `[:tymeslot, :booking, :created]` for a successful booking."
  @spec booking_created() :: :ok
  def booking_created do
    :telemetry.execute([:tymeslot, :booking, :created], %{count: 1}, %{})
  end
end
