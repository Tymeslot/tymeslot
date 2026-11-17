defmodule Tymeslot.MeetingPayments.BookingPayments do
  @moduledoc """
  Reading booking payment records: a host's payments and the refunds they
  still owe, the payment behind a meeting or a series and the meetings it
  paid for, and a charge's Stripe receipt.

  A public sibling of `Tymeslot.MeetingPayments`, callable from anywhere the
  context is.
  """

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.HeldMeetings
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState

  @typedoc """
  How many refunds a host still owes, and how much of each currency.
  """
  @type outstanding_refunds_summary :: %{
          count: non_neg_integer(),
          totals: [%{currency: String.t(), amount_cents: non_neg_integer()}]
        }

  @doc """
  Lists recent booking payments for a host, newest first.
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
    do: BookingPaymentQueries.outstanding_refunds_for_host(host_user_id, opts)

  @doc """
  Summarises the host's outstanding refunds: how many there are, and how much
  is owed in each currency.

  Unbounded, unlike `list_outstanding_refunds_for_host/2`, so a caller can say
  "showing 50 of 63" instead of truncating in silence, and so the disconnect
  confirmation can name what the host is about to walk away from.
  """
  @spec outstanding_refunds_summary_for_host(integer()) :: outstanding_refunds_summary()
  def outstanding_refunds_summary_for_host(host_user_id),
    do: BookingPaymentQueries.outstanding_refunds_summary_for_host(host_user_id)

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
    # The adapter normalises every read response to a string-keyed map, so the
    # receipt URL lives under the "receipt_url" string key regardless of whether
    # the production stripity struct or a Mox stub produced it.
    case StripeAdapter.retrieve_charge(charge_id, connect_account: account_id) do
      {:ok, %{"receipt_url" => url}} when is_binary(url) and url != "" -> {:ok, url}
      {:ok, _other} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end
end
