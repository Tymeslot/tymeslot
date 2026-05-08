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

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(pending paid failed refunded partially_refunded disputed)

  @type t :: %__MODULE__{}

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

    field :status, :string, default: "pending"
    field :paid_at, :utc_datetime
    field :refunded_amount_cents, :integer, default: 0

    field :last_event_id, :string
    field :host_deleted_at, :utc_datetime

    belongs_to :meeting, MeetingSchema, type: :binary_id

    timestamps()
  end

  @required_on_create ~w(
    stripe_account_id host_user_id host_email
    attendee_email meeting_type_name
    amount_cents currency application_fee_cents
  )a

  @castable @required_on_create ++
              ~w(
                meeting_id host_name attendee_name booking_theme_id
                stripe_checkout_session_id stripe_payment_intent_id stripe_charge_id
                status paid_at refunded_amount_cents last_event_id host_deleted_at
              )a

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @castable)
    |> validate_required(@required_on_create)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_number(:application_fee_cents, greater_than_or_equal_to: 0)
    |> validate_refunded_bounds()
    |> unique_constraint(:meeting_id)
    |> unique_constraint(:stripe_checkout_session_id)
    |> unique_constraint(:stripe_payment_intent_id)
    |> unique_constraint(:stripe_charge_id)
    |> check_constraint(:refunded_amount_cents, name: :refunded_amount_within_bounds)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(schema, attrs) do
    schema
    |> cast(attrs, @castable -- @required_on_create)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_refunded_bounds()
    |> check_constraint(:refunded_amount_cents, name: :refunded_amount_within_bounds)
  end

  @spec valid_statuses() :: [String.t()]
  def valid_statuses, do: @valid_statuses

  defp validate_refunded_bounds(changeset) do
    refunded = get_field(changeset, :refunded_amount_cents) || 0
    amount = get_field(changeset, :amount_cents) || 0

    cond do
      refunded < 0 ->
        add_error(changeset, :refunded_amount_cents, "must be non-negative")

      refunded > amount ->
        add_error(changeset, :refunded_amount_cents, "cannot exceed amount_cents")

      true ->
        changeset
    end
  end
end
