defmodule Tymeslot.Repo.Migrations.MakeSeatPaymentParticipantUnique do
  @moduledoc """
  One seat payment per participant: `booking_payments_participant_id_index`
  becomes a partial unique index over seat payments that name a participant.

  A participant is the seat one payment bought, so a second seat payment
  naming the same participant would be read as theirs by nobody
  (`BookingPaymentQueries.by_participant_id/1` returns the earliest) yet
  counted twice by anything joining payments to participants.

  Self-healing: should duplicates exist, the earliest seat payment
  (`inserted_at`, then `id`, the order the read above already uses) keeps the
  participant and the later ones are unlinked from it. They keep their
  meeting, amount and status, so they still show on the payments page and can
  be refunded from there; only the claim on a participant they never bought
  is dropped.

  `down/0` puts back the plain index `20261117171055` created. The unlinked duplicates stay
  unlinked: which participant they named is not recorded anywhere to restore.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # `booking_payments` is small, so plain (non-concurrent) index builds are
  # acceptable, as in `20261117171055`. The raw statement is the
  # deduplication the unique index needs before it can be built.

  @index :booking_payments_participant_id_index

  def up do
    execute("""
    UPDATE booking_payments AS b
       SET participant_id = NULL
      FROM (
        SELECT id,
               row_number() OVER (
                 PARTITION BY participant_id ORDER BY inserted_at, id
               ) AS position
          FROM booking_payments
         WHERE participant_id IS NOT NULL AND seat_payment
      ) AS ranked
     WHERE b.id = ranked.id AND ranked.position > 1
    """)

    drop_if_exists(index(:booking_payments, [:participant_id], name: @index))

    create(
      unique_index(:booking_payments, [:participant_id],
        name: @index,
        where: "participant_id IS NOT NULL AND seat_payment"
      )
    )
  end

  def down do
    drop_if_exists(index(:booking_payments, [:participant_id], name: @index))
    create(index(:booking_payments, [:participant_id], name: @index))
  end
end
