defmodule Tymeslot.MeetingPayments.BookingPaymentQueries do
  @moduledoc """
  All Repo.* calls for booking_payments.
  """

  import Ecto.Query

  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Repo

  @outstanding_refunds_limit 50

  @doc """
  Fetches a `booking_payment` by id and acquires a `SELECT … FOR UPDATE` row
  lock for the duration of the current transaction.

  Must be called inside a `Repo.transaction/1`. Returns
  `{:ok, schema}` or `{:error, :not_found}`.
  """
  @spec get_for_update(Ecto.UUID.t()) ::
          {:ok, BookingPaymentSchema.t()} | {:error, :not_found}
  def get_for_update(id) do
    query = from(b in BookingPaymentSchema, where: b.id == ^id, lock: "FOR UPDATE")

    case Repo.one(query) do
      nil -> {:error, :not_found}
      schema -> {:ok, schema}
    end
  end

  @doc """
  Like `get_for_update/1`, but only matches a payment taken by `host_user_id`.

  Ownership is part of the locked query, so it is decided under the same row
  lock as everything the caller validates afterwards. A malformed id, an
  unknown id and another host's payment all return `{:error, :not_found}`.
  """
  @spec get_for_update(term(), integer()) ::
          {:ok, BookingPaymentSchema.t()} | {:error, :not_found}
  def get_for_update(id, host_user_id) when is_integer(host_user_id) do
    with {:ok, uuid} <- cast_id(id) do
      query =
        from(b in BookingPaymentSchema,
          where: b.id == ^uuid and b.host_user_id == ^host_user_id,
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        nil -> {:error, :not_found}
        schema -> {:ok, schema}
      end
    end
  end

  @spec get(Ecto.UUID.t()) :: BookingPaymentSchema.t() | nil
  def get(id), do: Repo.get(BookingPaymentSchema, id)

  @doc """
  Fetches a payment by id only if `host_user_id` took it, or `nil`.

  A malformed id returns `nil` rather than raising, since the id usually comes
  from the client.
  """
  @spec get_for_host(term(), integer()) :: BookingPaymentSchema.t() | nil
  def get_for_host(id, host_user_id) when is_integer(host_user_id) do
    case cast_id(id) do
      {:ok, uuid} -> Repo.get_by(BookingPaymentSchema, id: uuid, host_user_id: host_user_id)
      {:error, :not_found} -> nil
    end
  end

  @spec by_meeting_id(Ecto.UUID.t()) :: BookingPaymentSchema.t() | nil
  def by_meeting_id(meeting_id),
    do: Repo.get_by(BookingPaymentSchema, meeting_id: meeting_id)

  @doc """
  Fetches the payment for a meeting only if `host_user_id` took it, or `nil`.
  """
  @spec by_meeting_id_for_host(term(), integer()) :: BookingPaymentSchema.t() | nil
  def by_meeting_id_for_host(meeting_id, host_user_id) when is_integer(host_user_id) do
    case cast_id(meeting_id) do
      {:ok, uuid} ->
        Repo.get_by(BookingPaymentSchema, meeting_id: uuid, host_user_id: host_user_id)

      {:error, :not_found} ->
        nil
    end
  end

  @spec by_checkout_session(String.t()) :: BookingPaymentSchema.t() | nil
  def by_checkout_session(session_id),
    do: Repo.get_by(BookingPaymentSchema, stripe_checkout_session_id: session_id)

  @spec by_charge_id(String.t()) :: BookingPaymentSchema.t() | nil
  def by_charge_id(charge_id),
    do: Repo.get_by(BookingPaymentSchema, stripe_charge_id: charge_id)

  @spec by_payment_intent_id(String.t()) :: BookingPaymentSchema.t() | nil
  def by_payment_intent_id(payment_intent_id),
    do: Repo.get_by(BookingPaymentSchema, stripe_payment_intent_id: payment_intent_id)

  @doc """
  Lists all `pending` booking payments for a host that still carry a
  `stripe_checkout_session_id`, with the associated meeting preloaded.

  Used by `Tymeslot.MeetingPayments.ConnectAccounts.disconnect/1` to
  collect open checkout sessions that must be expired before disconnecting.
  """
  @spec list_pending_for_host(integer()) :: [BookingPaymentSchema.t()]
  def list_pending_for_host(host_user_id) do
    query =
      from b in BookingPaymentSchema,
        where:
          b.host_user_id == ^host_user_id and
            b.status == "pending" and
            not is_nil(b.stripe_checkout_session_id),
        preload: [:meeting]

    Repo.all(query)
  end

  @doc """
  Lists `pending` booking payments that were created on or before `cutoff`
  and still carry a `stripe_checkout_session_id`.

  Used by `Tymeslot.MeetingPayments.Workers.ReconcileAwaitingPayments` to
  identify rows whose webhook never arrived so that they can be reconciled
  by polling Stripe directly.
  """
  @spec list_stale_pending(DateTime.t(), keyword()) :: [BookingPaymentSchema.t()]
  def list_stale_pending(%DateTime{} = cutoff, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    query =
      from b in BookingPaymentSchema,
        where:
          b.status == "pending" and
            b.inserted_at <= ^cutoff and
            not is_nil(b.stripe_checkout_session_id),
        order_by: [asc: b.inserted_at],
        limit: ^limit

    Repo.all(query)
  end

  @spec for_host(integer(), keyword()) :: [BookingPaymentSchema.t()]
  def for_host(host_user_id, opts) do
    limit = Keyword.get(opts, :limit, 25)

    query =
      from b in BookingPaymentSchema,
        where: b.host_user_id == ^host_user_id,
        order_by: [desc: b.inserted_at],
        limit: ^limit

    Repo.all(query)
  end

  @doc """
  Lists the host's payments whose meeting has been cancelled while the host
  still holds the attendee's money.

  Derived from the meeting's status and the payment's own balance rather than
  from a stored "refund owed" flag, so it cannot drift out of step with either
  side. Ordered oldest cancellation first: the longer an attendee has been out
  of pocket, the more urgent the row.

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
      from [_b, m] in outstanding_refunds_query(host_user_id),
        order_by: [asc: m.cancelled_at],
        limit: ^limit,
        preload: [meeting: m]

    Repo.all(query)
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
    # `amount_cents - refunded_amount_cents` is the SQL twin of
    # `Refunds.refundable_remaining_cents/1`; the `where` above guarantees it
    # is positive, so the `max(_, 0)` clamp has nothing to do here. The sum is
    # typed because Ecto cannot infer a type through the subtraction and would
    # otherwise hand back a `Decimal` where every other amount in the codebase
    # is an integer count of cents.
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

  # Cancelled bookings whose money the host still holds. Derived from the
  # meeting's status and the payment's own balance rather than from a stored
  # "refund owed" flag, so it cannot drift out of step with either side.
  defp outstanding_refunds_query(host_user_id) do
    from b in BookingPaymentSchema,
      join: m in assoc(b, :meeting),
      where:
        b.host_user_id == ^host_user_id and
          b.status in ^BookingPaymentSchema.refundable_statuses() and
          b.refunded_amount_cents < b.amount_cents and
          m.status == "cancelled"
  end

  @doc """
  Returns the count of `pending` booking payments for a host.

  Used by the payments dashboard to display an accurate pending count
  regardless of the paginated window returned by `for_host/2`.
  """
  @spec count_pending_for_host(integer()) :: non_neg_integer()
  def count_pending_for_host(host_user_id) do
    query =
      from b in BookingPaymentSchema,
        where: b.host_user_id == ^host_user_id and b.status == "pending",
        select: count(b.id)

    Repo.one(query)
  end

  @spec lifetime_stats(integer()) :: %{
          received: integer(),
          refunded: integer(),
          platform_fee: integer()
        }
  def lifetime_stats(host_user_id) do
    query =
      from b in BookingPaymentSchema,
        where:
          b.host_user_id == ^host_user_id and
            b.status in ["paid", "partially_refunded", "refunded"],
        select: %{
          received: coalesce(sum(b.amount_cents), 0),
          refunded: coalesce(sum(b.refunded_amount_cents), 0),
          platform_fee: coalesce(sum(b.application_fee_cents), 0)
        }

    Repo.one(query)
  end

  @spec insert(map()) :: {:ok, BookingPaymentSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    attrs
    |> BookingPaymentSchema.create_changeset()
    |> Repo.insert()
  end

  @spec update(BookingPaymentSchema.t(), map()) ::
          {:ok, BookingPaymentSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(schema, attrs) do
    schema
    |> BookingPaymentSchema.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Atomically marks a booking payment as `failed` only when its current status is
  `pending`.

  Uses a conditional `UPDATE … WHERE id = ? AND status = 'pending'` so a
  concurrent `checkout.session.completed` webhook that has already flipped the
  row to `paid` will not be overwritten. Must be called inside a
  `Repo.transaction/1`.

  Returns `{:ok, :cancelled}` when the row was updated, `{:ok, :skipped}` when
  the row was not in `pending` status (or was not found), and `{:error, reason}`
  on unexpected failures.
  """
  @spec cancel_if_pending(Ecto.UUID.t(), DateTime.t()) ::
          {:ok, :cancelled | :skipped} | {:error, term()}
  def cancel_if_pending(id, now) do
    query =
      from b in BookingPaymentSchema,
        where: b.id == ^id and b.status == "pending"

    case Repo.update_all(query, set: [status: "failed", updated_at: now]) do
      {1, _rows} -> {:ok, :cancelled}
      {0, _rows} -> {:ok, :skipped}
    end
  rescue
    exception -> {:error, exception}
  end

  @spec anonymise_for_host(integer(), DateTime.t()) :: {non_neg_integer(), nil}
  def anonymise_for_host(host_user_id, now) do
    query =
      from b in BookingPaymentSchema,
        where: b.host_user_id == ^host_user_id and is_nil(b.host_deleted_at)

    Repo.update_all(query,
      set: [
        attendee_email: nil,
        attendee_name: nil,
        meeting_type_name: "[deleted]",
        booking_theme_id: nil,
        host_deleted_at: now,
        updated_at: now
      ]
    )
  end

  defp cast_id(id) do
    case UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end
end
