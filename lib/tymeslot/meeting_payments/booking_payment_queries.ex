defmodule Tymeslot.MeetingPayments.BookingPaymentQueries do
  @moduledoc """
  All Repo.* calls for booking_payments.
  """

  import Ecto.Query

  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Repo

  @outstanding_refunds_limit 50

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

  # Payment `b`'s application fee less the share its refunds returned.
  defmacrop net_application_fee(b) do
    quote do
      fragment(
        "COALESCE(?, 0) - COALESCE(ROUND(COALESCE(?, 0)::numeric * ? / NULLIF(?, 0)), 0)",
        unquote(b).application_fee_cents,
        unquote(b).application_fee_cents,
        unquote(b).stripe_refunded_cents,
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

  @doc """
  The seat payment that paid for the participant `participant_id`, or `nil`
  for a free seat or an id that names nobody.
  """
  @spec by_participant_id(term()) :: BookingPaymentSchema.t() | nil
  def by_participant_id(participant_id) do
    case cast_id(participant_id) do
      {:ok, uuid} ->
        # One at most: `booking_payments_participant_id_index` is unique over
        # seat payments.
        BookingPaymentSchema
        |> where([b], b.participant_id == ^uuid and b.seat_payment)
        |> Repo.one()

      {:error, :not_found} ->
        nil
    end
  end

  @doc "The payment opened for the seat hold `hold_id`, or `nil`. A malformed id returns `nil`."
  @spec by_seat_hold_id(term()) :: BookingPaymentSchema.t() | nil
  def by_seat_hold_id(hold_id) do
    case cast_id(hold_id) do
      {:ok, uuid} -> Repo.get_by(BookingPaymentSchema, seat_hold_id: uuid)
      {:error, :not_found} -> nil
    end
  end

  @doc """
  As `by_seat_hold_id/1`, holding the row `FOR UPDATE` for the rest of the
  current transaction. Must be called inside a `Repo.transaction/1`.
  """
  @spec lock_by_seat_hold_id(term()) :: BookingPaymentSchema.t() | nil
  def lock_by_seat_hold_id(hold_id) do
    case cast_id(hold_id) do
      {:ok, uuid} ->
        BookingPaymentSchema
        |> where([b], b.seat_hold_id == ^uuid)
        |> lock("FOR UPDATE")
        |> Repo.one()

      {:error, :not_found} ->
        nil
    end
  end

  @doc """
  The seat payments of the seats still live on the group meeting
  `meeting_id`, oldest first: each linked to a participant who has not
  cancelled. A payment whose hold never became a seat (no participant: its
  hold was refused or released before converting) and the payment of a
  participant who has left are not returned.
  """
  @spec list_for_live_seats(Ecto.UUID.t()) :: [BookingPaymentSchema.t()]
  def list_for_live_seats(meeting_id) do
    BookingPaymentSchema
    |> join(:inner, [b], p in assoc(b, :participant))
    |> where([b, p], b.meeting_id == ^meeting_id and b.seat_payment and is_nil(p.cancelled_at))
    |> order_by([b], asc: b.inserted_at, asc: b.id)
    |> Repo.all()
  end

  @doc """
  Points the seat payment of the participant `old_participant_id` at
  `new_participant` on `new_meeting`, in one update, returning how many
  rows it moved (0 for a free seat).

  The update locks the payment row, and its caller already holds the
  meeting locks of the move: meetings first, payment after, the reverse of
  the order a webhook takes (`Tymeslot.MeetingPayments.Webhooks.LockedPayment`: payment, then
  meeting). That is safe only because no webhook for a converted seat's
  payment (the only kind this moves) takes a meeting lock: a dispute or a
  refund event locks the payment alone. A future webhook handler that
  locks a meeting under a converted seat's payment must keep it so, or
  take its locks in this order, or it can deadlock with a seat move.
  """
  @spec move_to_participant(binary(), %{id: binary()}, %{id: binary()}) :: non_neg_integer()
  def move_to_participant(old_participant_id, %{id: participant_id}, %{id: meeting_id})
      when is_binary(old_participant_id) do
    {count, _rows} =
      BookingPaymentSchema
      |> where([b], b.participant_id == ^old_participant_id and b.seat_payment)
      |> Repo.update_all(
        set: [
          participant_id: participant_id,
          meeting_id: meeting_id,
          updated_at: DateTime.utc_now(:second)
        ]
      )

    count
  end

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

    query |> with_pending_refund_cents() |> Repo.all()
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

  @doc """
  Whether a seat checkout of a host's is still pending: a booker holds seats
  on one of their group meetings, which may have been confirmed by others
  already, and has not yet paid.
  """
  @spec pending_seat_payment_for_host?(integer()) :: boolean()
  def pending_seat_payment_for_host?(host_user_id) do
    BookingPaymentSchema
    |> where([b], b.host_user_id == ^host_user_id and b.seat_payment and b.status == :pending)
    |> Repo.exists?()
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

  @doc "Links a converted seat payment to its participant and meeting (`BookingPaymentSchema.convert_changeset/2`)."
  @spec link_seat(BookingPaymentSchema.t(), map()) ::
          {:ok, BookingPaymentSchema.t()} | {:error, Ecto.Changeset.t()}
  def link_seat(schema, attrs) do
    schema
    |> BookingPaymentSchema.convert_changeset(attrs)
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
