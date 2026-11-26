defmodule Tymeslot.MeetingPayments.BookingPayments do
  @moduledoc """
  Reading booking payment records: a host's payments and the refunds they
  still owe, the payment behind a meeting or a series and the meetings it
  paid for, and a charge's Stripe receipt.

  A public sibling of `Tymeslot.MeetingPayments`, callable from anywhere the
  context is.
  """

  alias Tymeslot.Integrations.Stripe.Charges
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.HeldMeetings
  alias Tymeslot.MeetingPayments.OutstandingRefundQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.SeatPaymentQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState

  @typedoc """
  How many refunds a host still owes, and how much of each currency.
  """
  @type outstanding_refunds_summary :: %{
          count: non_neg_integer(),
          totals: [%{currency: String.t(), amount_cents: non_neg_integer()}]
        }

  @typedoc """
  A group meeting's paid seats as its host's cancellation settles them
  (`seat_money/1`): those it can refund, and those outside the refund window.
  """
  @type seat_money :: %{
          count: non_neg_integer(),
          totals: [%{currency: String.t(), amount_cents: non_neg_integer()}],
          outside_window: outstanding_refunds_summary()
        }

  @doc """
  Lists recent booking payments for a host, newest first, leaving out
  checkouts that never captured anything (`BookingPaymentQueries.for_host/2`).
  """
  @spec list_payments_for_host(integer(), keyword()) :: [BookingPaymentSchema.t()]
  def list_payments_for_host(host_user_id, opts \\ []),
    do: BookingPaymentQueries.for_host(host_user_id, opts)

  @doc """
  Lists the host's cancelled bookings that still hold the attendee's money,
  and expired ones paid after their slot was taken. Oldest first, by when
  the booking was cancelled, or by when it was paid for one that never was
  (an expired booking), with ties broken by payment id.

  Not bounded by `list_payments_for_host/2`'s recent-payments window, so an
  older unrefunded cancellation stays visible instead of scrolling out of
  sight.
  """
  @spec list_outstanding_refunds_for_host(integer(), keyword()) :: [BookingPaymentSchema.t()]
  def list_outstanding_refunds_for_host(host_user_id, opts \\ []),
    do: OutstandingRefundQueries.outstanding_refunds_for_host(host_user_id, opts)

  @doc """
  Summarises the host's outstanding refunds: how many there are, and how much
  is owed in each currency.

  Unbounded, unlike `list_outstanding_refunds_for_host/2`, so a caller can say
  "showing 50 of 63" instead of truncating in silence, and so the disconnect
  confirmation can name what the host is about to walk away from.
  """
  @spec outstanding_refunds_summary_for_host(integer()) :: outstanding_refunds_summary()
  def outstanding_refunds_summary_for_host(host_user_id),
    do: OutstandingRefundQueries.outstanding_refunds_summary_for_host(host_user_id)

  @doc """
  Returns the total count of pending booking payments for a host.

  Unlike `list_payments_for_host/2`, this is not bounded by any pagination
  limit and always reflects the true pending count across all rows.
  """
  @spec count_pending_payments_for_host(integer()) :: non_neg_integer()
  def count_pending_payments_for_host(host_user_id),
    do: BookingPaymentQueries.count_pending_for_host(host_user_id)

  @doc """
  Returns lifetime payment totals for a host, one entry per currency.
  """
  @spec lifetime_stats_for_host(integer()) :: [
          %{
            currency: String.t(),
            received: integer(),
            refunded: integer(),
            platform_fee: integer()
          }
        ]
  def lifetime_stats_for_host(host_user_id),
    do: BookingPaymentQueries.lifetime_stats(host_user_id)

  @doc """
  Fetches a booking payment by ID, or `nil` if not found.

  Unscoped: for workers and system rules only. A lookup driven by a signed-in
  user must use `get_payment_for_host/2`.
  """
  @spec get_payment(Ecto.UUID.t()) :: BookingPaymentSchema.t() | nil
  def get_payment(id), do: BookingPaymentQueries.get(id)

  @doc """
  The payment opened for the seat hold `hold_id`, or `nil`. Unscoped, as
  `get_payment/1`: for workers and system rules only.
  """
  @spec payment_for_seat_hold(Ecto.UUID.t()) :: BookingPaymentSchema.t() | nil
  def payment_for_seat_hold(hold_id), do: SeatPaymentQueries.by_seat_hold_id(hold_id)

  @doc """
  Fetches a booking payment by ID only if `host_user_id` took it.

  Another host's payment, an unknown id and a malformed id all return
  `{:error, :not_found}`, so the answer discloses nothing about payments the
  caller does not own.
  """
  @spec get_payment_for_host(term(), integer()) ::
          {:ok, BookingPaymentSchema.t()} | {:error, :not_found}
  def get_payment_for_host(id, host_user_id) do
    case BookingPaymentQueries.get_for_host(id, host_user_id) do
      nil -> {:error, :not_found}
      payment -> {:ok, payment}
    end
  end

  @doc """
  Fetches the booking payment that paid for a meeting, or `nil`: the
  meeting's own, or, for a session of a paid series, the series' one
  payment (with its `series` preloaded), which pays for every session.
  Every lookup of a meeting's payment goes through here (or
  `payment_for_meeting/2`), so none forgets the series.

  Unscoped: for system rules only. A lookup on behalf of a signed-in user must
  use `payment_for_meeting/2`.
  """
  @spec payment_for_meeting(term()) :: BookingPaymentSchema.t() | nil
  def payment_for_meeting(meeting_id), do: BookingPaymentQueries.for_meeting(meeting_id)

  @doc """
  The seat payment of a participant of a group meeting, or `nil` for a free
  seat. A group meeting's seat payments belong to its participants, so
  `payment_for_meeting/1` never returns one.

  Unscoped: for system rules only.
  """
  @spec payment_for_participant(term()) :: BookingPaymentSchema.t() | nil
  def payment_for_participant(participant_id),
    do: SeatPaymentQueries.by_participant_id(participant_id)

  @doc """
  How many of `payments` there are and how much of their money each currency
  still holds (`Refunds.refundable_remaining_cents/1`), currencies in
  alphabetical order: the seats a host's cancellation of a group meeting
  refunds, or leaves to be refunded by hand, as its emails tell the organiser.

  Pure: summarises the list it is given, so a caller that reads the seats
  under the meeting's lock and sizes the refunds from them reports exactly
  those seats.
  """
  @spec seat_money_summary([BookingPaymentSchema.t()]) :: outstanding_refunds_summary()
  def seat_money_summary(payments) do
    totals =
      payments
      |> Enum.group_by(& &1.currency, &Refunds.refundable_remaining_cents/1)
      |> Enum.sort_by(fn {currency, _amounts} -> currency end)
      |> Enum.map(fn {currency, amounts} ->
        %{currency: currency, amount_cents: Enum.sum(amounts)}
      end)

    %{count: length(payments), totals: totals}
  end

  @doc """
  Splits seat payments into those Tymeslot can still refund
  (`Refunds.refundable?/1`) and the rest, paid more than 60 days ago, which
  only the host's Stripe dashboard can refund. Each keeps its order.
  """
  @spec split_by_refund_window([BookingPaymentSchema.t()]) ::
          {[BookingPaymentSchema.t()], [BookingPaymentSchema.t()]}
  def split_by_refund_window(payments), do: Enum.split_with(payments, &Refunds.refundable?/1)

  @doc """
  What a host's cancellation of a group meeting does with the money of
  `payments`: the seats Tymeslot can still refund, summarised as
  `seat_money_summary/1` does, and under `:outside_window` the seats paid
  too long ago for that (`split_by_refund_window/1`), which the host must
  refund from Stripe.

  Pure, like `seat_money_summary/1`.
  """
  @spec seat_money([BookingPaymentSchema.t()]) :: seat_money()
  def seat_money(payments) do
    {refundable, outside_window} = split_by_refund_window(payments)
    Map.put(seat_money_summary(refundable), :outside_window, seat_money_summary(outside_window))
  end

  @doc """
  The meetings a booking payment paid for: its meeting, or every session of
  its series in series order; `[]` once they are gone. See
  `HeldMeetings.meetings_for/1`.
  """
  @spec meetings_for_payment(BookingPaymentSchema.t()) :: [MeetingSchema.t()]
  defdelegate meetings_for_payment(payment), to: HeldMeetings, as: :meetings_for

  @doc """
  Whether none of the meetings a booking payment paid for goes ahead any
  more (each cancelled, expired or otherwise released), so whatever of it
  remains is owed back. The rule the outstanding-refunds list applies.
  """
  @spec series_released?(BookingPaymentSchema.t()) :: boolean()
  def series_released?(payment) do
    case HeldMeetings.meetings_for(payment) do
      [] -> false
      meetings -> Enum.all?(meetings, &MeetingState.released_status?(&1.status))
    end
  end

  @doc """
  The seat payments `host_user_id` took on the group meeting `meeting_id`
  that still hold some of the attendee's money (`Refunds.refund_outstanding?/1`),
  oldest first: what cancelling the meeting refunds.

  Only the seats live when it is read count: a payment linked to a
  participant who has not cancelled. A payment whose hold never became a
  seat is settled by its own path (one refused at checkout by
  `Tymeslot.MeetingPayments.Workers.RefundLatePayment`), so it is not
  refunded twice, nor counted as a paid seat. A participant who left before the host cancelled is not
  refunded here either: leaving refunds nothing automatically, and the
  host can still refund them from the payments page.
  """
  @spec seat_payments_for_meeting(Ecto.UUID.t(), integer()) :: [BookingPaymentSchema.t()]
  def seat_payments_for_meeting(meeting_id, host_user_id) when is_integer(host_user_id) do
    {outstanding, _disputed} = live_seat_payments_for_meeting(meeting_id, host_user_id)
    outstanding
  end

  @doc """
  The seat payments `host_user_id` took on the group meeting `meeting_id`,
  from one read of its live seats, as `{outstanding, disputed}`, each
  oldest first: those `seat_payments_for_meeting/2` returns, and those a
  dispute holds, which it leaves out because the card network has their
  money. A live seat with neither (refunded in full, say) is in neither.

  One read, so a seat whose dispute closes meanwhile cannot fall between
  two of them and be in neither list.
  """
  @spec live_seat_payments_for_meeting(Ecto.UUID.t(), integer()) ::
          {[BookingPaymentSchema.t()], [BookingPaymentSchema.t()]}
  def live_seat_payments_for_meeting(meeting_id, host_user_id) when is_integer(host_user_id) do
    meeting_id
    |> SeatPaymentQueries.list_for_live_seats()
    |> Enum.filter(&(&1.host_user_id == host_user_id))
    |> Enum.reduce({[], []}, fn
      %{status: :disputed} = payment, {outstanding, disputed} ->
        {outstanding, [payment | disputed]}

      payment, {outstanding, disputed} ->
        if Refunds.refund_outstanding?(payment),
          do: {[payment | outstanding], disputed},
          else: {outstanding, disputed}
    end)
    |> then(fn {outstanding, disputed} -> {Enum.reverse(outstanding), Enum.reverse(disputed)} end)
  end

  @doc "Fetches the one booking payment of a paid series, or `nil`."
  @spec payment_for_series(term()) :: BookingPaymentSchema.t() | nil
  def payment_for_series(series_id), do: BookingPaymentQueries.by_series_id(series_id)

  @doc """
  Fetches the booking payment for a meeting only if `host_user_id` took it,
  or `nil`.

  Someone else who can see the meeting (its attendee, for instance) gets `nil`,
  exactly as for an unpaid meeting: the payment is the host's business.
  """
  @spec payment_for_meeting(term(), integer()) :: BookingPaymentSchema.t() | nil
  def payment_for_meeting(meeting_id, host_user_id),
    do: BookingPaymentQueries.for_meeting_for_host(meeting_id, host_user_id)

  @doc """
  Fetches the Stripe-hosted receipt URL for a charge via the Connect API.

  Returns `{:ok, url}` when a URL is present, `{:ok, nil}` when the charge
  has no receipt URL, or `{:error, reason}` when the Stripe call fails.
  """
  @spec retrieve_charge_receipt_url(charge_id :: String.t(), account_id :: String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def retrieve_charge_receipt_url(charge_id, account_id) do
    case Charges.retrieve(charge_id, connect_account: account_id) do
      {:ok, %{"receipt_url" => url}} when is_binary(url) and url != "" -> {:ok, url}
      {:ok, _other} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end
end
