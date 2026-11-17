defmodule Tymeslot.Migrations.AddSeatHoldsToBookingPaymentsTest do
  @moduledoc """
  Verifies `20261117171055_add_seat_holds_to_booking_payments`: existing rows
  read as one non-seat seat. The invariants the migration adds are covered by
  `BookingPaymentSchemaTest`, which runs by default.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :database
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_117_171_055

  test "existing payments read as one seat" do
    MigrationRunner.down!(@version)

    id = UUID.generate()
    now = DateTime.utc_now(:second)

    Repo.query!(
      """
      INSERT INTO booking_payments
        (id, stripe_account_id, host_user_id, host_email, meeting_type_name,
         amount_cents, currency, application_fee_cents, status, refunded_amount_cents,
         inserted_at, updated_at)
      VALUES ($1, 'acct_old', 1, 'h@x.test', 'Consult', 5000, 'eur', 25, 'pending', 0, $2, $2)
      """,
      [UUID.dump!(id), now]
    )

    MigrationRunner.up!(@version)

    assert %{rows: [[1, false]]} =
             Repo.query!("SELECT seats, seat_payment FROM booking_payments WHERE id = $1", [
               UUID.dump!(id)
             ])
  end
end
