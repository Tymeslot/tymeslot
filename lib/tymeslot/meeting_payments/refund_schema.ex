defmodule Tymeslot.MeetingPayments.RefundSchema do
  @moduledoc """
  A refund Tymeslot intends to make of a booking payment, recorded before
  Stripe is asked for it (`Tymeslot.MeetingPayments.Refunds`).

  status values:
    * pending    — recorded; counts against the refundable balance
    * succeeded  — Stripe accepted it; its amount is in the payment's
      `refunded_amount_cents`
    * failed     — Stripe refused it, or every attempt failed

  `attempt` counts the attempts made (each names its own idempotency key),
  and `executing_until` is the lease of the one attempt in flight.

  `source` says what decided the refund. `:external` is a refund made outside
  Tymeslot (in the Stripe dashboard) and recorded from Stripe; callers never
  request one.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.MeetingPayments.BookingPaymentSchema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @requestable_sources [:host, :cancellation, :approval_release, :late_payment, :series_host]
  @sources @requestable_sources ++ [:external]
  @statuses [:pending, :succeeded, :failed]

  @type source ::
          :host | :cancellation | :approval_release | :late_payment | :series_host | :external
  @type status :: :pending | :succeeded | :failed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          booking_payment_id: Ecto.UUID.t() | nil,
          amount_cents: pos_integer() | nil,
          source: source() | nil,
          status: status(),
          attempt: non_neg_integer(),
          stripe_refund_id: String.t() | nil,
          failure_code: String.t() | nil,
          reason: String.t() | nil,
          legacy_idempotency_key: String.t() | nil,
          legacy_since: DateTime.t() | nil,
          requested_by_user_id: integer() | nil,
          executing_until: DateTime.t() | nil,
          settled_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "booking_payment_refunds" do
    belongs_to :booking_payment, BookingPaymentSchema, type: :binary_id

    field :amount_cents, :integer
    field :source, Ecto.Enum, values: @sources
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :attempt, :integer, default: 0
    field :stripe_refund_id, :string
    field :failure_code, :string
    field :reason, :string
    field :legacy_idempotency_key, :string
    field :legacy_since, :utc_datetime_usec
    field :requested_by_user_id, :integer
    field :executing_until, :utc_datetime
    field :settled_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "The sources a caller may request a refund under."
  @spec requestable_sources() :: [source(), ...]
  def requestable_sources, do: @requestable_sources

  @doc "A pending refund of `amount_cents` of a payment, as a caller requests it."
  @spec request_changeset(t(), map()) :: Ecto.Changeset.t()
  def request_changeset(refund, attrs) do
    refund
    |> cast(attrs, [
      :booking_payment_id,
      :amount_cents,
      :source,
      :reason,
      :legacy_idempotency_key,
      :legacy_since,
      :requested_by_user_id
    ])
    |> validate_required([:booking_payment_id, :amount_cents, :source])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_inclusion(:source, @requestable_sources)
    |> validate_legacy_key_dated()
    |> foreign_key_constraint(:booking_payment_id)
    |> foreign_key_constraint(:requested_by_user_id)
    |> check_constraint(:amount_cents, name: :amount_positive)
  end

  # A legacy key is replayed only while Stripe may still keep it, which is
  # reckoned from when it could first have been sent.
  defp validate_legacy_key_dated(changeset) do
    keyed? = not is_nil(get_field(changeset, :legacy_idempotency_key))
    dated? = not is_nil(get_field(changeset, :legacy_since))

    changeset =
      if keyed? == dated?,
        do: changeset,
        else: add_error(changeset, :legacy_since, "must be set exactly when a legacy key is")

    check_constraint(changeset, :legacy_since, name: :legacy_key_dated)
  end

  @doc "The end of a refund: `succeeded` with Stripe's refund id, or `failed` with a code."
  @spec settle_changeset(t(), map()) :: Ecto.Changeset.t()
  def settle_changeset(refund, attrs) do
    refund
    |> cast(attrs, [:status, :stripe_refund_id, :failure_code, :settled_at])
    |> validate_required([:status, :settled_at])
    |> validate_inclusion(:status, [:succeeded, :failed])
    |> unique_constraint(:stripe_refund_id)
  end
end
