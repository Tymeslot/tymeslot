defmodule Tymeslot.MeetingPayments.BookingPaymentSchema do
  @moduledoc """
  Payment record for a paid meeting. Snapshots host/attendee identity and
  meeting-type details so the row survives meeting deletion and host
  anonymisation (retention).

  status values:
    * pending             — Checkout Session created, awaiting webhook
    * paid                — checkout.session.completed received
    * failed              — Checkout Session expired or attendee cancelled
    * partially_refunded  — host issued at least one partial refund
    * refunded            — full amount refunded
    * disputed            — Stripe dispute opened on the charge
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatHoldSchema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses [:pending, :paid, :failed, :refunded, :partially_refunded, :disputed]
  @refundable_statuses [:paid, :partially_refunded]

  @type status :: :pending | :paid | :failed | :refunded | :partially_refunded | :disputed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          stripe_account_id: String.t() | nil,
          host_user_id: integer() | nil,
          host_email: String.t() | nil,
          host_name: String.t() | nil,
          attendee_email: String.t() | nil,
          attendee_name: String.t() | nil,
          meeting_type_name: String.t() | nil,
          booking_theme_id: String.t() | nil,
          stripe_checkout_session_id: String.t() | nil,
          stripe_payment_intent_id: String.t() | nil,
          stripe_charge_id: String.t() | nil,
          amount_cents: integer() | nil,
          currency: String.t() | nil,
          application_fee_cents: integer() | nil,
          status: status(),
          paid_at: DateTime.t() | nil,
          refunded_amount_cents: integer(),
          stripe_refunded_cents: integer(),
          disputed_lost_cents: integer(),
          pending_refund_cents: non_neg_integer() | nil,
          last_event_id: String.t() | nil,
          stripe_dispute_id: String.t() | nil,
          dispute_closed_at: DateTime.t() | nil,
          host_deleted_at: DateTime.t() | nil,
          meeting_id: Ecto.UUID.t() | nil,
          series_id: Ecto.UUID.t() | nil,
          seat_hold_id: Ecto.UUID.t() | nil,
          participant_id: Ecto.UUID.t() | nil,
          seats: integer(),
          seat_payment: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "booking_payments" do
    field :stripe_account_id, :string
    field :host_user_id, :integer
    field :host_email, :string
    field :host_name, :string
    field :attendee_email, :string
    field :attendee_name, :string
    field :meeting_type_name, :string
    field :booking_theme_id, :string

    field :stripe_checkout_session_id, :string
    field :stripe_payment_intent_id, :string
    field :stripe_charge_id, :string

    field :amount_cents, :integer
    field :currency, :string
    field :application_fee_cents, :integer

    field :status, Ecto.Enum, values: @valid_statuses, default: :pending
    field :paid_at, :utc_datetime
    # Everything given back to the attendee, within the amount paid: the
    # refunds made at Stripe (`stripe_refunded_cents`) plus what a lost
    # dispute took (`disputed_lost_cents`). See
    # `Tymeslot.MeetingPayments.RefundedTotal`.
    field :refunded_amount_cents, :integer, default: 0
    field :stripe_refunded_cents, :integer, default: 0
    field :disputed_lost_cents, :integer, default: 0
    # What the payment's pending refunds add up to, filled in by the queries
    # that list payments for a host (`BookingPaymentQueries`); `nil` when the
    # query that loaded the row did not read it.
    field :pending_refund_cents, :integer, virtual: true

    field :last_event_id, :string

    # The Stripe dispute this payment last saw, and when it closed. Lets a
    # `charge.dispute.created` that Stripe delivers after its own
    # `charge.dispute.closed` be told apart from a new dispute.
    field :stripe_dispute_id, :string
    field :dispute_closed_at, :utc_datetime
    field :host_deleted_at, :utc_datetime

    # Per-seat pricing on a group meeting: the booker pays `price × seats`.
    # `seat_payment` is the immutable marker of a seat's payment (several may
    # share one meeting); `seat_hold_id` is nilified when settled holds are
    # deleted, so it cannot be that marker.
    field :seats, :integer, default: 1
    field :seat_payment, :boolean, default: false

    belongs_to :meeting, MeetingSchema, type: :binary_id
    # A paid series has one payment, owned by the series (`meeting_id` nil).
    belongs_to :series, Tymeslot.BookingSeries.SeriesSchema, type: :binary_id
    belongs_to :seat_hold, SeatHoldSchema
    belongs_to :participant, ParticipantSchema

    timestamps(type: :utc_datetime)
  end

  @required_on_create ~w(
    stripe_account_id host_user_id host_email
    meeting_type_name
    amount_cents currency application_fee_cents
  )a

  @castable @required_on_create ++
              ~w(
                meeting_id host_name attendee_email attendee_name booking_theme_id
                stripe_checkout_session_id stripe_payment_intent_id stripe_charge_id
                status paid_at refunded_amount_cents stripe_refunded_cents disputed_lost_cents last_event_id
                host_deleted_at
                stripe_dispute_id dispute_closed_at
              )a

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:series_id, :seat_hold_id, :participant_id, :seats | @castable])
    |> validate_required(@required_on_create)
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_number(:application_fee_cents, greater_than_or_equal_to: 0)
    |> validate_refunded_bounds()
    |> put_seat_payment()
    |> unique_constraint(:meeting_id)
    |> unique_constraint(:series_id)
    |> unique_constraint(:seat_hold_id, name: :booking_payments_seat_hold_id_index)
    |> unique_participant()
    |> check_constraint(:seats, name: :booking_payments_seats_positive)
    |> check_constraint(:series_id, name: :booking_payments_single_owner_check)
    |> unique_constraint(:stripe_checkout_session_id)
    |> unique_constraint(:stripe_payment_intent_id)
    |> unique_constraint(:stripe_charge_id)
    |> check_constraint(:refunded_amount_cents, name: :refunded_amount_within_bounds)
    |> check_constraint(:stripe_refunded_cents, name: :stripe_refunded_within_amount)
    |> check_constraint(:disputed_lost_cents, name: :disputed_lost_within_refunded)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(schema, attrs) do
    schema
    |> cast(attrs, @castable -- @required_on_create)
    |> validate_refunded_bounds()
    |> unique_constraint(:stripe_charge_id)
    |> check_constraint(:refunded_amount_cents, name: :refunded_amount_within_bounds)
    |> check_constraint(:stripe_refunded_cents, name: :stripe_refunded_within_amount)
    |> check_constraint(:disputed_lost_cents, name: :disputed_lost_within_refunded)
  end

  @doc "Moves a seat payment to another meeting (a rescheduled seat) and its participant."
  @spec move_seat_changeset(t(), map()) :: Ecto.Changeset.t()
  def move_seat_changeset(%__MODULE__{seat_payment: seat_payment} = schema, attrs) do
    changeset =
      schema
      |> cast(attrs, [:meeting_id, :participant_id])
      |> validate_required([:meeting_id, :participant_id])
      |> foreign_key_constraint(:meeting_id)
      |> foreign_key_constraint(:participant_id)
      |> unique_participant()

    if seat_payment,
      do: changeset,
      else: add_error(changeset, :seat_payment, "is not a seat payment")
  end

  @doc """
  Links a seat payment to the participant its hold became, and to that
  participant's meeting: a hold whose meeting lapsed before its payment
  landed can convert onto another one.
  """
  @spec convert_changeset(t(), map()) :: Ecto.Changeset.t()
  def convert_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:participant_id, :meeting_id])
    |> validate_required([:participant_id, :meeting_id])
    |> foreign_key_constraint(:participant_id)
    |> foreign_key_constraint(:meeting_id)
    |> unique_participant()
  end

  @spec valid_statuses() :: [status()]
  def valid_statuses, do: @valid_statuses

  @doc """
  The statuses in which the host still holds some of the attendee's money.

  `refunded` is absent because nothing is left to give back, and `disputed`
  because Stripe has taken the decision out of the host's hands. Defined here
  so the refund rule and the queries that look for outstanding refunds read
  the same list.
  """
  @spec refundable_statuses() :: [status()]
  def refundable_statuses, do: @refundable_statuses

  # A participant is the seat one payment bought: a second seat payment
  # naming them is refused by the partial unique index.
  defp unique_participant(changeset),
    do:
      unique_constraint(changeset, :participant_id, name: :booking_payments_participant_id_index)

  # A payment taken for a hold is a seat payment, and stays one when its hold
  # is later deleted; callers cannot set the marker themselves.
  defp put_seat_payment(changeset) do
    if get_change(changeset, :seat_hold_id),
      do: put_change(changeset, :seat_payment, true),
      else: changeset
  end

  defp validate_refunded_bounds(changeset) do
    refunded = get_field(changeset, :refunded_amount_cents) || 0
    amount = get_field(changeset, :amount_cents) || 0

    cond do
      refunded < 0 ->
        add_error(changeset, :refunded_amount_cents, "must be non-negative")

      refunded > amount ->
        add_error(changeset, :refunded_amount_cents, "cannot exceed amount_cents")

      (get_field(changeset, :disputed_lost_cents) || 0) not in 0..refunded//1 ->
        add_error(changeset, :disputed_lost_cents, "must be within refunded_amount_cents")

      (get_field(changeset, :stripe_refunded_cents) || 0) not in 0..amount//1 ->
        add_error(changeset, :stripe_refunded_cents, "must be within amount_cents")

      true ->
        changeset
    end
  end
end
