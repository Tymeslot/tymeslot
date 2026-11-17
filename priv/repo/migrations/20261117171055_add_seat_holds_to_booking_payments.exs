defmodule Tymeslot.Repo.Migrations.AddSeatHoldsToBookingPayments do
  @moduledoc """
  A paid group meeting takes one payment per booker, so several
  `booking_payments` rows may now share a `meeting_id`.

  `seat_payment` is the immutable marker of such a row. `seat_hold_id` cannot
  be: it is `nilify_all` and settled holds are deleted after 30 days, which
  would leave several payments on one meeting with a NULL `seat_hold_id` and
  collide with the meeting index. The `meeting_id` unique index therefore
  narrows to non-seat payments (same name, so the existing
  `unique_constraint(:meeting_id)` still maps), and `seat_hold_id` gets its own
  partial unique index.

  Existing rows take the column defaults (`seats = 1`, `seat_payment = false`),
  so no backfill is needed. `booking_payments_single_owner_check` is
  untouched: a seat payment has a meeting and no series. There is no check
  tying `seat_payment` to `seat_hold_id`, and none requiring a meeting, because
  `meeting_id` is `nilify_all` and the row must outlive its meeting.

  The `seat_hold_id` foreign key is deferred (see the comment in `up/0`): a
  meeting delete would otherwise fail on a payment that references one of the
  meeting's holds.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file column_removed
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # The reference columns are new and empty, so their foreign keys validate no
  # row. The defaulted columns are constant defaults, which Postgres adds
  # without rewriting the table. `booking_payments` is small, so plain
  # (non-concurrent) indexes are acceptable. The raw statements are the
  # VALIDATE step after a NOT VALID constraint and a constraint drop.

  def up do
    alter table(:booking_payments) do
      add_if_not_exists(
        :seat_hold_id,
        references(:seat_holds, type: :binary_id, on_delete: :nilify_all)
      )

      add_if_not_exists(
        :participant_id,
        references(:meeting_participants, type: :binary_id, on_delete: :nilify_all)
      )

      add_if_not_exists(:seats, :integer, null: false, default: 1)
      add_if_not_exists(:seat_payment, :boolean, null: false, default: false)
    end

    # Deleting a meeting cascades to its holds and nilifies the payments' `meeting_id`
    # in the same statement. Postgres fires the hold cascade first, so the
    # payment row is updated while its `seat_hold_id` still names a hold that is
    # already gone, and an immediate check rejects the whole delete. Deferring
    # the check to commit sees the final row, `seat_hold_id` already NULL.
    execute("""
    ALTER TABLE booking_payments
      ALTER CONSTRAINT booking_payments_seat_hold_id_fkey DEFERRABLE INITIALLY DEFERRED
    """)

    execute("ALTER TABLE booking_payments DROP CONSTRAINT IF EXISTS booking_payments_seats_positive")

    create(
      constraint(:booking_payments, :booking_payments_seats_positive,
        check: "seats >= 1",
        validate: false
      )
    )

    execute("ALTER TABLE booking_payments VALIDATE CONSTRAINT booking_payments_seats_positive")

    drop_if_exists(
      index(:booking_payments, [:meeting_id], name: :booking_payments_meeting_id_index)
    )

    create(
      unique_index(:booking_payments, [:meeting_id],
        name: :booking_payments_meeting_id_index,
        where: "meeting_id IS NOT NULL AND NOT seat_payment"
      )
    )

    drop_if_exists(
      index(:booking_payments, [:seat_hold_id], name: :booking_payments_seat_hold_id_index)
    )

    create(
      unique_index(:booking_payments, [:seat_hold_id],
        name: :booking_payments_seat_hold_id_index,
        where: "seat_hold_id IS NOT NULL"
      )
    )

    drop_if_exists(
      index(:booking_payments, [:participant_id], name: :booking_payments_participant_id_index)
    )

    create(index(:booking_payments, [:participant_id], name: :booking_payments_participant_id_index))
  end

  def down do
    drop_if_exists(
      index(:booking_payments, [:participant_id], name: :booking_payments_participant_id_index)
    )

    drop_if_exists(
      index(:booking_payments, [:seat_hold_id], name: :booking_payments_seat_hold_id_index)
    )

    drop_if_exists(
      index(:booking_payments, [:meeting_id], name: :booking_payments_meeting_id_index)
    )

    create(
      unique_index(:booking_payments, [:meeting_id],
        name: :booking_payments_meeting_id_index,
        where: "meeting_id IS NOT NULL"
      )
    )

    execute("ALTER TABLE booking_payments DROP CONSTRAINT IF EXISTS booking_payments_seats_positive")

    alter table(:booking_payments) do
      remove_if_exists(:seat_payment, :boolean)
      remove_if_exists(:seats, :integer)
      remove_if_exists(:participant_id, references(:meeting_participants, type: :binary_id))
      remove_if_exists(:seat_hold_id, references(:seat_holds, type: :binary_id))
    end
  end
end
