defmodule Tymeslot.MeetingPayments.RefundSchema do
  @moduledoc """
  A refund Tymeslot intends to make of a booking payment, recorded before
  Stripe is asked for it (`Tymeslot.MeetingPayments.Refunds`).

  status values:
    * pending    — recorded; counts against the refundable balance
    * succeeded  — Stripe accepted it; its amount is in the payment's
      `refunded_amount_cents`
    * failed     — Stripe refused it, or every attempt failed

  `attempt` counts the attempts made, and `executing_until` is the lease of
  the one attempt in flight. `key_attempt` is the attempt whose idempotency
  key the refund's requests are sent under: claimed with the attempt that
  first sends it, kept while Stripe has answered no request under it (a
  timeout, a conflict with a request still in flight), and given up once
  Stripe has stored an answer to replay (`nil`, so the next attempt takes
  its own).

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

  # The failure codes of a refund Stripe itself ended (`RefundOutcome`).
  @ended_at_stripe_codes ["refund_failed", "refund_canceled"]

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
          key_attempt: pos_integer() | nil,
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
    field :key_attempt, :integer
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

  @doc """
  The failure codes of a refund Stripe reported `failed` or `canceled`.
  Stripe never revives such a refund, so a refund failed with one of them
  is final: a report saying otherwise is an older one arriving late.
  """
  @spec ended_at_stripe_codes() :: [String.t(), ...]
  def ended_at_stripe_codes, do: @ended_at_stripe_codes

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

  @doc """
  A refund made outside Tymeslot, recorded from Stripe as `succeeded`:
  `attrs` carry its payment, amount, Stripe refund id and `settled_at`.
  """
  @spec external_changeset(t(), map()) :: Ecto.Changeset.t()
  def external_changeset(refund, attrs) do
    refund
    |> cast(attrs, [:booking_payment_id, :amount_cents, :stripe_refund_id, :settled_at])
    |> validate_required([:booking_payment_id, :amount_cents, :stripe_refund_id, :settled_at])
    |> validate_number(:amount_cents, greater_than: 0)
    |> put_change(:source, :external)
    |> put_change(:status, :succeeded)
    |> foreign_key_constraint(:booking_payment_id)
    |> check_constraint(:amount_cents, name: :amount_positive)
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
