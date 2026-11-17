defmodule Tymeslot.Repo.Migrations.AddSeriesIdToBookingPayments do
  @moduledoc """
  A paid series takes one payment for all of its sessions, so the
  `booking_payments` row belongs to the series (`series_id`, `meeting_id`
  NULL) rather than to a meeting.

  `series_id` is nullable and starts empty. The partial unique index allows
  one payment per series; the existing `meeting_id` unique index is
  untouched. `booking_payments_single_owner_check` forbids a row owned by both
  a meeting and a series. Every existing row has a NULL `series_id`, so the
  check holds without a backfill; it is added `NOT VALID` and then validated, a pattern kept
  for its habit: the migration runs in one DDL transaction, so the lock is held
  throughout, but `booking_payments` is small and the new column is empty, so
  the scan is trivial.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file column_removed
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # The reference column is new and empty, so its foreign key validates no
  # row. `booking_payments` is small, so a plain (non-concurrent) index is
  # acceptable. The raw statement is the VALIDATE step after the NOT VALID
  # constraint.

  def up do
    alter table(:booking_payments) do
      add_if_not_exists(
        :series_id,
        references(:booking_series, type: :binary_id, on_delete: :nilify_all)
      )
    end

    # Data preparation for the unique index, as `CredoChecks.MigrationConstraintSafety`
    # asks of every one. The column was added empty a moment ago and the
    # migration runs in one transaction, so this matches no row: it states
    # that no existing payment can violate the index, rather than repairing one.
    execute("UPDATE booking_payments SET series_id = NULL WHERE series_id IS NOT NULL")

    drop_if_exists(
      index(:booking_payments, [:series_id], name: :booking_payments_series_id_index)
    )

    create(
      unique_index(:booking_payments, [:series_id],
        name: :booking_payments_series_id_index,
        where: "series_id IS NOT NULL"
      )
    )

    execute(
      "ALTER TABLE booking_payments DROP CONSTRAINT IF EXISTS booking_payments_single_owner_check"
    )

    create(
      constraint(:booking_payments, :booking_payments_single_owner_check,
        check: "meeting_id IS NULL OR series_id IS NULL",
        validate: false
      )
    )

    execute(
      "ALTER TABLE booking_payments VALIDATE CONSTRAINT booking_payments_single_owner_check"
    )
  end

  def down do
    execute(
      "ALTER TABLE booking_payments DROP CONSTRAINT IF EXISTS booking_payments_single_owner_check"
    )

    drop_if_exists(
      index(:booking_payments, [:series_id], name: :booking_payments_series_id_index)
    )

    alter table(:booking_payments) do
      remove_if_exists(:series_id, references(:booking_series, type: :binary_id))
    end
  end
end
