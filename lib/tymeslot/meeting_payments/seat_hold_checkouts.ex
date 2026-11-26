defmodule Tymeslot.MeetingPayments.SeatHoldCheckouts do
  @moduledoc """
  What becomes of a seat hold's checkout when the hold ends without being
  paid for: its open Stripe Checkout expired once the hold is released for a
  cancelled meeting, and its pending payment failed when the checkout could
  never be opened. Opening and abandoning a checkout is
  `Tymeslot.MeetingPayments.CheckoutSessions`.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.CheckoutSessions
  alias Tymeslot.MeetingPayments.SeatPaymentQueries
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.SeatHoldSchema

  @doc """
  After the transaction that released `holds` for a cancelled meeting has
  committed: expires each hold's open checkout (`CheckoutSessions.abandon_seat_checkout/1`)
  and tells its booker's payment page it expired. Best effort: a checkout
  Stripe completes anyway is refunded in full, its hold having been
  released for a cancelled meeting, so a failure to expire one is logged
  and the rest go on.
  """
  @spec abandon_released_seat_holds([SeatHoldSchema.t()]) :: :ok
  def abandon_released_seat_holds(holds) when is_list(holds) do
    Enum.each(holds, fn hold ->
      case CheckoutSessions.abandon_seat_checkout(hold.id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not expire the checkout of a seat hold on a cancelled meeting",
            seat_hold_id: hold.id,
            reason: LogFormat.reason(reason)
          )
      end

      SeatHolds.broadcast(hold.id, :expired)
    end)
  end

  @doc """
  Fails the pending payment opened for the seat hold `hold_id`, whose
  checkout could not be opened, locking it first. Must run inside the
  transaction releasing the hold, before the meeting and the hold are
  locked (payment, meeting, hold is the order every path takes).

  Stripe may have created the session even though the call creating it
  failed or timed out, so without this the row would stay `pending` with no
  session id, which nothing ever settles. Returns `{:ok, :unchanged}` when
  there is no pending payment for the hold.
  """
  @spec fail_seat_payment(String.t()) ::
          {:ok, BookingPaymentSchema.t() | :unchanged} | {:error, Ecto.Changeset.t()}
  def fail_seat_payment(hold_id) do
    case SeatPaymentQueries.lock_by_seat_hold_id(hold_id) do
      %BookingPaymentSchema{status: :pending} = payment ->
        BookingPaymentQueries.update(payment, %{status: :failed})

      _settled_or_missing ->
        {:ok, :unchanged}
    end
  end
end
