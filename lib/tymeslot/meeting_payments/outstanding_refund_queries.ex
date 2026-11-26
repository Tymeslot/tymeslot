defmodule Tymeslot.MeetingPayments.OutstandingRefundQueries do
  @moduledoc """
  Queries for the host's outstanding refunds: the bookings, seats and series
  whose money the host still holds although nothing of what it paid for goes
  ahead. The rest of the `booking_payments` queries are in
  `Tymeslot.MeetingPayments.BookingPaymentQueries`.
  """

  import Ecto.Query

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Repo

  @outstanding_refunds_limit 50

  @doc """
  Lists the host's payments whose meeting has been cancelled while the host
  still holds the attendee's money, and those whose meeting expired before
  it was settled: a payment that completed after its slot was taken, or a
  paid request that lapsed unapproved, whose automatic refund has not gone
  through (yet). A paid seat its participant cancelled is listed too, with
  that participant preloaded: the session goes ahead, so only the
  participant says the money is owed.

  Derived from the meeting's status and the payment's own balance rather than
  from a stored "refund owed" flag, so it cannot drift out of step with either
  side. Oldest first, the longer an attendee has been out of pocket the more
  urgent the row: a cancelled booking (or seat) dated by its cancellation, an expired
  one, which has no cancellation date, by its payment. Ties go by id, so the
  bounded window below is the same rows on every read.

  Deliberately not bounded by `for_host/2`'s recent-payments window, which is
  what let an older unrefunded cancellation drop off the dashboard entirely.
  It is still bounded, at `#{@outstanding_refunds_limit}` rows, so pair it with
  `outstanding_refunds_summary_for_host/1` and say how many rows the window is
  hiding rather than truncating in silence.
  """
  @spec outstanding_refunds_for_host(integer(), keyword()) :: [BookingPaymentSchema.t()]
  def outstanding_refunds_for_host(host_user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @outstanding_refunds_limit)

    query =
      from [b, m, p] in outstanding_refunds_query(host_user_id),
        order_by: [
          asc: fragment("COALESCE(?, ?, ?)", p.cancelled_at, m.cancelled_at, b.paid_at),
          asc: b.id
        ],
        limit: ^limit,
        preload: [meeting: m, participant: p]

    query |> BookingPaymentQueries.with_pending_refund_cents() |> Repo.all()
  end

  @doc """
  Summarises every outstanding refund a host owes: how many rows there are,
  and how much is still owed in each currency.

  Unbounded on purpose, and sharing its `where` with
  `outstanding_refunds_for_host/2` so the two cannot drift: the card needs the
  true count to report its own truncation, and the disconnect confirmation
  needs the total before the host walks away from it.

  Totals are per currency rather than one sum, because a host who changed
  their default currency can be holding money in more than one.
  """
  @spec outstanding_refunds_summary_for_host(integer()) :: %{
          count: non_neg_integer(),
          totals: [%{currency: String.t(), amount_cents: non_neg_integer()}]
        }
  def outstanding_refunds_summary_for_host(host_user_id) do
    # What is not refunded yet, a pending refund's share included: the
    # attendee is owed it until the refund settles. The `where` above
    # guarantees it is positive. The sum is typed because Ecto cannot infer
    # a type through the subtraction and would otherwise hand back a
    # `Decimal` where every other amount in the codebase is an integer count
    # of cents.
    query =
      from b in outstanding_refunds_query(host_user_id),
        group_by: b.currency,
        order_by: [asc: b.currency],
        select: %{
          currency: b.currency,
          count: count(b.id),
          amount_cents: type(sum(b.amount_cents - b.refunded_amount_cents), :integer)
        }

    rows = Repo.all(query)

    %{
      count: Enum.sum(Enum.map(rows, & &1.count)),
      totals: Enum.map(rows, &Map.take(&1, [:currency, :amount_cents]))
    }
  end

  # Cancelled or expired bookings whose money the host still holds, the
  # paid seats their participants cancelled (the session goes ahead, and a
  # participant's own cancellation refunds nothing), and the seats paid for
  # but never booked (refused at checkout, their slot full say), which are
  # owed in full whatever became of the session. A moved seat is not
  # one: its payment points at the live participant it became. A paid
  # booking ends expired when its payment completed after the slot was taken
  # (`CheckoutSessionCompleted`), or when a paid request lapsed unapproved
  # (`Meetings.Approval`); both owe a full refund and refund it on their own,
  # so a row here is one whose refund has not gone through yet; one still
  # pending stays listed until it settles. Derived
  # from the meeting's status and the payment's own balance rather than from
  # a stored "refund owed" flag, so it cannot drift out of step with either
  # side.
  defp outstanding_refunds_query(host_user_id) do
    from b in BookingPaymentSchema,
      as: :payment,
      join: m in MeetingSchema,
      as: :meeting,
      # The payment's meeting, or its series' first session still there:
      # one equality on the meeting id, so the join stays a primary-key
      # lookup per payment.
      on:
        m.id ==
          fragment(
            "COALESCE(?, (SELECT sm.id FROM meetings AS sm WHERE sm.series_id = ? ORDER BY sm.series_position LIMIT 1))",
            b.meeting_id,
            b.series_id
          ),
      where:
        b.host_user_id == ^host_user_id and
          b.status in ^BookingPaymentSchema.refundable_statuses() and
          b.refunded_amount_cents < b.amount_cents,
      left_join: p in ParticipantSchema,
      as: :participant,
      on: p.id == b.participant_id,
      where: is_nil(b.series_id) or not exists(series_sessions_going_ahead()),
      where:
        m.status in ^MeetingState.released() or not is_nil(p.cancelled_at) or
          (b.seat_payment and is_nil(b.participant_id))
  end

  # A paid series' one payment is owed back once none of its sessions goes
  # ahead (a late payment refused, say); it is listed by its first session
  # still there, whichever position that is.
  # One session cancelled alone is refunded its share when the host cancels
  # it, and the rest still pays for the sessions going ahead.
  defp series_sessions_going_ahead do
    MeetingState.where_not_released(
      from(m in MeetingSchema, where: m.series_id == parent_as(:payment).series_id)
    )
  end
end
