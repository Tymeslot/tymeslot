defmodule Tymeslot.Repo.Migrations.CreateBookingPayments do
  @moduledoc """
  One row per paid meeting (1:1 with meetings). Snapshots host and
  attendee identity, meeting-type name, theme id, currency, amounts, and
  Stripe references. The meeting_id FK is nilify so the row survives
  cascade deletion of the meeting (retention requirement).

  host_user_id is a bare integer with NO foreign key — also for retention,
  so the row stands alone after the user is deleted.
  """

  use Ecto.Migration

  def change do
    create table(:booking_payments, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:meeting_id, references(:meetings, type: :binary_id, on_delete: :nilify_all))

      add(:stripe_account_id, :string, null: false)
      add(:host_user_id, :integer, null: false)
      add(:host_email, :string, null: false)
      add(:host_name, :string)
      add(:attendee_email, :string, null: false)
      add(:attendee_name, :string)
      add(:meeting_type_name, :string, null: false)
      add(:booking_theme_id, :string)

      add(:stripe_checkout_session_id, :string)
      add(:stripe_payment_intent_id, :string)
      add(:stripe_charge_id, :string)

      add(:amount_cents, :bigint, null: false)
      add(:currency, :string, size: 3, null: false)
      add(:application_fee_cents, :bigint, null: false)

      add(:status, :string, null: false, default: "pending")
      add(:paid_at, :utc_datetime)
      add(:refunded_amount_cents, :bigint, null: false, default: 0)

      add(:last_event_id, :string)
      add(:host_deleted_at, :utc_datetime)

      timestamps()
    end

    create(unique_index(:booking_payments, [:meeting_id], where: "meeting_id IS NOT NULL"))

    create(
      unique_index(:booking_payments, [:stripe_checkout_session_id],
        where: "stripe_checkout_session_id IS NOT NULL"
      )
    )

    create(
      unique_index(:booking_payments, [:stripe_payment_intent_id],
        where: "stripe_payment_intent_id IS NOT NULL"
      )
    )

    create(
      unique_index(:booking_payments, [:stripe_charge_id], where: "stripe_charge_id IS NOT NULL")
    )

    create(index(:booking_payments, [:host_user_id]))
    create(index(:booking_payments, [:status]))
    create(index(:booking_payments, [:host_deleted_at]))

    create(
      constraint(:booking_payments, :refunded_amount_within_bounds,
        check: "refunded_amount_cents >= 0 AND refunded_amount_cents <= amount_cents"
      )
    )
  end
end
