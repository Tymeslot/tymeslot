defmodule Tymeslot.MeetingPayments.BookingPaymentQueries do
  @moduledoc """
  All Repo.* calls for booking_payments.
  """

  import Ecto.Query

  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  # What `DisputeLossBackfill` reads of a candidate; nothing about the
  # attendee.
  @dispute_loss_fields [
    :id,
    :stripe_charge_id,
    :stripe_account_id,
    :amount_cents,
    :refunded_amount_cents,
    :stripe_refunded_cents,
    :disputed_lost_cents,
    :status
  ]

  # The migrations after which this deployment recorded a dispute on its
  # payment (`stripe_dispute_id`), a lost dispute's share apart from the
  # refunds (`disputed_lost_cents`), and the refunds made apart from both
  # (`stripe_refunded_cents`).
  @dispute_tracking_migration 20_261_103_142_458
  @disputed_lost_migration 20_261_120_141_652
  @stripe_refunded_migration 20_261_124_084_318

  # When this deployment ran the migration `version`, by its own clock
  # (Ecto records it in UTC); a deployment's releases, not the calendar,
  # decide how it recorded a payment.
  defmacrop migrated_at(version) do
    quote do
      fragment(
        "(SELECT m.inserted_at FROM schema_migrations AS m WHERE m.version = ?)",
        unquote(version)
      )
    end
  end

  # What the pending refunds of the payment `id` add up to, correlated to the
  # row the enclosing query reads.
  defmacrop pending_refund_sum(id) do
    quote do
      fragment(
        "(SELECT COALESCE(SUM(r.amount_cents), 0)::integer FROM booking_payment_refunds AS r WHERE r.booking_payment_id = ? AND r.status = 'pending')",
        unquote(id)
      )
    end
  end

  # Payment `b`'s application fee less the share its refunds returned. Only
  # Tymeslot's own refunds ask Stripe to return the fee; one made in the
  # Stripe dashboard (`:external`) returns none, so its amount is taken off
  # the refunds made first. A refund made before refunds were recorded one
  # by one has no row and counts as Tymeslot's, which it was.
  defmacrop net_application_fee(b) do
    quote do
      fragment(
        "COALESCE(?, 0) - COALESCE(ROUND(COALESCE(?, 0)::numeric * GREATEST(? - (SELECT COALESCE(SUM(r.amount_cents), 0) FROM booking_payment_refunds AS r WHERE r.booking_payment_id = ? AND r.status = 'succeeded' AND r.source = 'external'), 0) / NULLIF(?, 0)), 0)",
        unquote(b).application_fee_cents,
        unquote(b).application_fee_cents,
        unquote(b).stripe_refunded_cents,
        unquote(b).id,
        unquote(b).amount_cents
      )
    end
  end

  @doc """
  Fills in each payment's `pending_refund_cents` (what its pending refunds
  add up to) as `query` reads it, so the refundable balance of a listed
  payment needs no query of its own.
  """
  @spec with_pending_refund_cents(Ecto.Queryable.t()) :: Ecto.Query.t()
  def with_pending_refund_cents(query),
    do: from(b in query, select_merge: %{pending_refund_cents: pending_refund_sum(b.id)})

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
      {:ok, uuid} ->
        BookingPaymentSchema
        |> where([b], b.id == ^uuid and b.host_user_id == ^host_user_id)
        |> with_pending_refund_cents()
        |> Repo.one()

      {:error, :not_found} ->
        nil
    end
  end

  @doc """
  The payment the meeting `meeting_id` owns itself, or `nil`: the one payment
  of a one-to-one booking. A session of a paid series owns none (see
  `for_meeting/1`), and a group meeting's seat payments, one per paying
  booker, are never returned here (`list_for_live_seats/1`).
  """
  @spec by_meeting_id(Ecto.UUID.t()) :: BookingPaymentSchema.t() | nil
  def by_meeting_id(meeting_id),
    do: Repo.one(own_payment(meeting_id))

  defp own_payment(meeting_id),
    do: where(BookingPaymentSchema, [b], b.meeting_id == ^meeting_id and not b.seat_payment)

  @doc "The payment the series `series_id` owns, or `nil`."
  @spec by_series_id(term()) :: BookingPaymentSchema.t() | nil
  def by_series_id(series_id) do
    case cast_id(series_id) do
      {:ok, uuid} -> Repo.get_by(BookingPaymentSchema, series_id: uuid)
      {:error, :not_found} -> nil
    end
  end

  @doc """
  The payment that paid for the meeting `meeting_id`, or `nil`: its own, or,
  for a session of a paid series, the series' one payment, returned with its
  `series` preloaded. A malformed id returns `nil`.
  """
  @spec for_meeting(term()) :: BookingPaymentSchema.t() | nil
  def for_meeting(meeting_id) do
    case cast_id(meeting_id) do
      {:ok, uuid} -> by_meeting_id(uuid) || series_payment(uuid, dynamic(true))
      {:error, :not_found} -> nil
    end
  end

  @doc """
  As `for_meeting/1`, but only a payment `host_user_id` took, or `nil`. A
  group meeting's seat payments are never returned, as there.
  """
  @spec for_meeting_for_host(term(), integer()) :: BookingPaymentSchema.t() | nil
  def for_meeting_for_host(meeting_id, host_user_id) when is_integer(host_user_id) do
    case cast_id(meeting_id) do
      {:ok, uuid} ->
        own =
          uuid
          |> own_payment()
          |> where([b], b.host_user_id == ^host_user_id)
          |> with_pending_refund_cents()
          |> Repo.one()

        own || series_payment(uuid, dynamic([bp], bp.host_user_id == ^host_user_id))

      {:error, :not_found} ->
        nil
    end
  end

  defp series_payment(meeting_id, scope) do
    BookingPaymentSchema
    |> join(:inner, [bp], m in MeetingSchema, on: m.series_id == bp.series_id)
    |> where([_bp, m], m.id == ^meeting_id)
    |> where(^scope)
    |> preload(:series)
    |> with_pending_refund_cents()
    |> Repo.one()
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
  `stripe_checkout_session_id`.

  Used by `Tymeslot.MeetingPayments.ConnectAccountRetirement.disconnect/1` to
  collect open checkout sessions that must be expired before disconnecting.
  """
  @spec list_pending_for_host(integer()) :: [BookingPaymentSchema.t()]
  def list_pending_for_host(host_user_id) do
    query =
      from b in BookingPaymentSchema,
        where:
          b.host_user_id == ^host_user_id and
            b.status == :pending and
            not is_nil(b.stripe_checkout_session_id)

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
          b.status == :pending and
            b.inserted_at <= ^cutoff and
            not is_nil(b.stripe_checkout_session_id),
        order_by: [asc: b.inserted_at],
        limit: ^limit

    Repo.all(query)
  end

  @doc """
  The host's recent payments, newest first: every charge that moved money,
  and none that never did. A checkout still `:pending`, or `:failed` with
  nothing captured (`paid_at` nil), is left out. Keyed on the payment row
  alone, never on the meeting: a late payment refused on an `:expired`
  meeting moved money and stays listed.
  """
  @spec for_host(integer(), keyword()) :: [BookingPaymentSchema.t()]
  def for_host(host_user_id, opts) do
    limit = Keyword.get(opts, :limit, 25)

    query =
      from b in BookingPaymentSchema,
        where:
          b.host_user_id == ^host_user_id and b.status != :pending and
            not (b.status == :failed and is_nil(b.paid_at)),
        order_by: [desc: b.inserted_at],
        limit: ^limit,
        # A seat payment's row names its session.
        preload: :meeting

    query |> with_pending_refund_cents() |> Repo.all()
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
        where: b.host_user_id == ^host_user_id and b.status == :pending,
        select: count(b.id)

    Repo.one(query)
  end

  @doc """
  Lifetime totals for a host, one row per currency, ordered by currency.

  Grouped because a host who changed their default currency holds money in
  more than one, and amounts in different currencies cannot be added up.

  `platform_fee` is net of the share Stripe returns with each refund, in
  proportion to the amount refunded. A lost dispute returns no fee.
  """
  @spec lifetime_stats(integer()) :: [
          %{
            currency: String.t(),
            received: integer(),
            refunded: integer(),
            platform_fee: integer()
          }
        ]
  def lifetime_stats(host_user_id) do
    query =
      from b in BookingPaymentSchema,
        where:
          b.host_user_id == ^host_user_id and
            b.status in [:paid, :partially_refunded, :refunded],
        group_by: b.currency,
        order_by: [asc: b.currency],
        select: %{
          currency: b.currency,
          received: type(coalesce(sum(b.amount_cents), 0), :integer),
          refunded: type(coalesce(sum(b.refunded_amount_cents), 0), :integer),
          platform_fee: type(coalesce(sum(net_application_fee(b)), 0), :integer)
        }

    Repo.all(query)
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
        where: b.id == ^id and b.status == :pending

    case Repo.update_all(query, set: [status: :failed, updated_at: now]) do
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

  @doc """
  Deletes the booking payments of deleted hosts whose statutory retention
  period has ended: every row anonymised by `anonymise_for_host/2` and dated
  before `cutoff`. A row is dated by when it was paid, or by when it was
  created if it never was.
  """
  @spec delete_retained_before(DateTime.t()) :: {non_neg_integer(), nil}
  def delete_retained_before(%DateTime{} = cutoff) do
    BookingPaymentSchema
    |> where([b], not is_nil(b.host_deleted_at))
    |> dated_before(cutoff)
    |> Repo.delete_all()
  end

  @doc """
  Scrubs the attendee's name and email from the booking payments of hosts who
  still exist, once the row's statutory retention period has ended (dated
  before `cutoff`, as for `delete_retained_before/1`). The row stays, so the
  host's own payment history keeps its amounts and dates.
  """
  @spec scrub_attendees_before(DateTime.t(), DateTime.t()) :: {non_neg_integer(), nil}
  def scrub_attendees_before(%DateTime{} = cutoff, now) do
    BookingPaymentSchema
    |> where([b], is_nil(b.host_deleted_at))
    |> where([b], not is_nil(b.attendee_email) or not is_nil(b.attendee_name))
    |> dated_before(cutoff)
    |> Repo.update_all(set: [attendee_email: nil, attendee_name: nil, updated_at: now])
  end

  @doc """
  Up to `limit` payments whose refund figures may misstate a lost dispute,
  in id order after `after_id` (`nil` for the first page): a charge, and
  either

    * something refunded, no dispute loss recorded and a refunded status,
      on a payment created before this deployment recorded losses apart
      (its `disputed_lost_cents` migration ran), and either created before
      it tracked disputes on the payment at all or carrying a dispute id;
    * or a loss recorded whose refunds and loss add up to exactly the
      amount paid, on a payment created before this deployment recorded
      the refunds apart (its `stripe_refunded_cents` migration ran).

  A payment created after those migrations ran was recorded by code that
  gets its figures right, so it is never read. Only the fields
  `Tymeslot.MeetingPayments.DisputeLossBackfill` reads are loaded (the
  others hold their defaults); its moduledoc says why these rows.
  """
  @spec dispute_loss_candidates(Ecto.UUID.t() | nil, pos_integer()) :: [
          BookingPaymentSchema.t()
        ]
  def dispute_loss_candidates(after_id, limit) when is_integer(limit) and limit > 0 do
    BookingPaymentSchema
    |> where(
      [b],
      not is_nil(b.stripe_charge_id) and
        ((b.disputed_lost_cents == 0 and b.refunded_amount_cents > 0 and
            b.status in [:refunded, :partially_refunded] and
            b.inserted_at < migrated_at(^@disputed_lost_migration) and
            (not is_nil(b.stripe_dispute_id) or
               b.inserted_at < migrated_at(^@dispute_tracking_migration))) or
           (b.disputed_lost_cents > 0 and
              b.stripe_refunded_cents + b.disputed_lost_cents == b.amount_cents and
              b.inserted_at < migrated_at(^@stripe_refunded_migration)))
    )
    |> after_id(after_id)
    |> order_by([b], asc: b.id)
    |> limit(^limit)
    |> select([b], struct(b, @dispute_loss_fields))
    |> Repo.all()
  end

  @doc """
  Writes `correction` (the refunds made, the lost dispute share, the
  refunded total and the status) to `payment`, only while the row still
  holds the figures and status `payment` was read with. Writes nothing
  else. `{:ok, :unchanged}` when the guard matched no row: another process
  changed the row first.
  """
  @spec record_dispute_loss(BookingPaymentSchema.t(), %{
          stripe_refunded_cents: non_neg_integer(),
          disputed_lost_cents: pos_integer(),
          refunded_amount_cents: pos_integer(),
          status: BookingPaymentSchema.status()
        }) :: {:ok, :recorded | :unchanged}
  def record_dispute_loss(
        %BookingPaymentSchema{id: id, refunded_amount_cents: read_total} = read,
        %{
          stripe_refunded_cents: refunds,
          disputed_lost_cents: lost,
          refunded_amount_cents: total,
          status: status
        }
      )
      when is_integer(refunds) and is_integer(lost) and lost > 0 and is_integer(total) and
             total >= read_total do
    query =
      from b in BookingPaymentSchema,
        where:
          b.id == ^id and b.stripe_refunded_cents == ^read.stripe_refunded_cents and
            b.disputed_lost_cents == ^read.disputed_lost_cents and
            b.refunded_amount_cents == ^read_total and b.status == ^read.status

    case Repo.update_all(query,
           set: [
             stripe_refunded_cents: refunds,
             disputed_lost_cents: lost,
             refunded_amount_cents: total,
             status: status
           ]
         ) do
      {1, _rows} -> {:ok, :recorded}
      {0, _rows} -> {:ok, :unchanged}
    end
  end

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: where(query, [b], b.id > ^id)

  defp dated_before(query, cutoff) do
    where(
      query,
      [b],
      coalesce(b.paid_at, b.inserted_at) < type(^cutoff, :utc_datetime)
    )
  end

  defp cast_id(id) do
    case UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end
end
