defmodule Tymeslot.MeetingPayments.BookingPaymentQueries do
  @moduledoc """
  All Repo.* calls for booking_payments.
  """

  import Ecto.Query

  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Repo

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

  @spec get(Ecto.UUID.t()) :: BookingPaymentSchema.t() | nil
  def get(id), do: Repo.get(BookingPaymentSchema, id)

  @spec by_meeting_id(Ecto.UUID.t()) :: BookingPaymentSchema.t() | nil
  def by_meeting_id(meeting_id),
    do: Repo.get_by(BookingPaymentSchema, meeting_id: meeting_id)

  @spec by_checkout_session(String.t()) :: BookingPaymentSchema.t() | nil
  def by_checkout_session(session_id),
    do: Repo.get_by(BookingPaymentSchema, stripe_checkout_session_id: session_id)

  @spec by_charge_id(String.t()) :: BookingPaymentSchema.t() | nil
  def by_charge_id(charge_id),
    do: Repo.get_by(BookingPaymentSchema, stripe_charge_id: charge_id)

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
  def for_host(host_user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 25)

    query =
      from b in BookingPaymentSchema,
        where: b.host_user_id == ^host_user_id,
        order_by: [desc: b.inserted_at],
        limit: ^limit

    Repo.all(query)
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
end
