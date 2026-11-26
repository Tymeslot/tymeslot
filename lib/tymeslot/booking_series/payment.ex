defmodule Tymeslot.BookingSeries.Payment do
  @moduledoc """
  Booking a paid series: every session held until the whole series is paid
  for, at once, in one Stripe Checkout.

  As for a single paid booking (`Tymeslot.Bookings.Create.PaidBooking`),
  each session is inserted `awaiting_payment` (conflict-checked, so it holds
  its slot), and nothing else: no calendar event, video
  room, reminder or confirmation, until the payment completes
  (`Tymeslot.MeetingPayments.Webhooks.SeriesCheckoutCompleted`). The
  sessions are inserted in the series' transaction; the checkout is opened
  once it has committed, never holding a connection across the Stripe call.
  A checkout that cannot be opened releases every session at once
  (`Checkout.expire_held_series/1`) rather than leaving them held
  until the reconciliation sweep.
  """

  require Logger

  alias Tymeslot.Bookings.Create.Persist
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.Meetings.MeetingSchema

  @doc """
  Inserts one session of a paid series, held for payment, inside the
  series' transaction. A series brings no guests
  (`Tymeslot.BookingSeries.Create` refuses them). Returns the meeting and
  the (empty) fan-out owed, or the insert's error.
  """
  @spec hold(map()) :: {:ok, {MeetingSchema.t(), []}} | {:error, term()}
  def hold(meeting_attrs) do
    with {:ok, meeting} <-
           Persist.create_meeting(Map.put(meeting_attrs, :status, :awaiting_payment)) do
      {:ok, {meeting, []}}
    end
  end

  @doc """
  Opens the series' checkout once its sessions are committed. On failure
  every session is released at once and `{:error, {:checkout_failed,
  reason}}` returned.
  """
  @spec checkout(SeriesSchema.t()) :: {:ok, String.t()} | {:error, {:checkout_failed, term()}}
  def checkout(%SeriesSchema{} = series) do
    case Checkout.create_checkout_session_for_series(series) do
      {:ok, %{checkout_url: url}} ->
        {:ok, url}

      {:error, reason} ->
        release(series, reason)
        {:error, {:checkout_failed, reason}}
    end
  end

  # Best effort, as for a single booking: a series that fails to expire is
  # left to the reconciliation sweep.
  defp release(series, reason) do
    case Checkout.expire_held_series(series) do
      {:ok, :expired, first} ->
        Checkout.announce_expired(first)

      {:ok, :unchanged, _first_id} ->
        :ok

      {:error, expire_error} ->
        Logger.warning("Failed to expire a series after checkout failure",
          series_id: series.id,
          checkout_error: LogFormat.reason(reason),
          expire_error: LogFormat.reason(expire_error)
        )
    end
  end
end
