defmodule Tymeslot.MeetingPayments.BookingPaymentQueries do
  @moduledoc """
  All Repo.* calls for booking_payments.
  """

  import Ecto.Query

  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Repo

  @spec by_meeting_id(Ecto.UUID.t()) :: BookingPaymentSchema.t() | nil
  def by_meeting_id(meeting_id),
    do: Repo.get_by(BookingPaymentSchema, meeting_id: meeting_id)

  @spec by_checkout_session(String.t()) :: BookingPaymentSchema.t() | nil
  def by_checkout_session(session_id),
    do: Repo.get_by(BookingPaymentSchema, stripe_checkout_session_id: session_id)

  @spec by_charge_id(String.t()) :: BookingPaymentSchema.t() | nil
  def by_charge_id(charge_id),
    do: Repo.get_by(BookingPaymentSchema, stripe_charge_id: charge_id)

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

    Repo.one(query) || %{received: 0, refunded: 0, platform_fee: 0}
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
    hash =
      :crypto.hash(:sha256, to_string(host_user_id))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    deleted_email = "deleted-#{hash}@deleted.local"

    query =
      from b in BookingPaymentSchema,
        where: b.host_user_id == ^host_user_id and is_nil(b.host_deleted_at)

    Repo.update_all(query,
      set: [
        attendee_email: deleted_email,
        attendee_name: "Deleted Attendee",
        meeting_type_name: "[deleted]",
        booking_theme_id: nil,
        host_deleted_at: now,
        updated_at: now
      ]
    )
  end
end
