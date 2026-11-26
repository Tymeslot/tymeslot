defmodule Tymeslot.Repo.Migrations.CreateBookingPaymentRefunds do
  @moduledoc """
  One row per refund Tymeslot intends to make of a booking payment, written
  before Stripe is asked for it, so a refund whose Stripe call timed out or
  whose process died is still known and can be finished.

  The table starts empty: every refund made before it existed is already in
  `booking_payments.refunded_amount_cents`, which stays the authoritative
  total. A row's `amount_cents` counts against the refundable balance only
  while it is `pending`.

  A refund row goes with its payment when the financial retention purge
  deletes the payment, as the rest of that record does.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  #
  # The table is created in this same migration and is empty, so the indexes,
  # foreign keys and checks build instantly and nothing can be blocked.

  def change do
    create table(:booking_payment_refunds, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :booking_payment_id,
          references(:booking_payments, type: :binary_id, on_delete: :delete_all),
          null: false

      add :amount_cents, :integer, null: false
      add :source, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :attempt, :integer, null: false, default: 0
      add :stripe_refund_id, :string
      add :failure_code, :string
      # The Stripe `reason` param, when the caller gives one.
      add :reason, :string
      # An idempotency key the refund was already sent under elsewhere,
      # used for its first attempt in place of the row's own.
      add :legacy_idempotency_key, :string
      # When the key could first have been sent, so when Stripe may stop
      # keeping it (24 hours on). Set exactly when the key is.
      add :legacy_since, :utc_datetime_usec
      add :requested_by_user_id, references(:users, on_delete: :nilify_all)
      # Single-flight lease: while in the future, one executor is attempting
      # the refund and no other may.
      add :executing_until, :utc_datetime
      add :settled_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:booking_payment_refunds, [:booking_payment_id])

    create index(:booking_payment_refunds, [:booking_payment_id],
             where: "status = 'pending'",
             name: :booking_payment_refunds_pending_index
           )

    create unique_index(:booking_payment_refunds, [:stripe_refund_id],
             where: "stripe_refund_id IS NOT NULL"
           )

    create constraint(:booking_payment_refunds, :amount_positive, check: "amount_cents > 0")

    create constraint(:booking_payment_refunds, :status_known,
             check: "status IN ('pending', 'succeeded', 'failed')"
           )

    create constraint(:booking_payment_refunds, :legacy_key_dated,
             check: "(legacy_idempotency_key IS NULL) = (legacy_since IS NULL)"
           )

    create constraint(:booking_payment_refunds, :source_known,
             check:
               "source IN ('host', 'cancellation', 'approval_release', 'late_payment', " <>
                 "'series_host', 'external')"
           )
  end
end
