defmodule Tymeslot.Migrations.AddStatusCheckToBookingPaymentsTest do
  @moduledoc """
  Verifies `20261029111111_add_status_check_to_booking_payments` backfills an
  out-of-vocabulary `status` from the money the row records, leaves known
  values alone, and then closes the column with a CHECK constraint.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :database
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_029_111_111

  test "derives a known status for each stray row and re-closes the constraint" do
    now = DateTime.utc_now(:second)

    refunded = insert(:booking_payment, paid_at: now, refunded_amount_cents: 5000)
    partial = insert(:booking_payment, paid_at: now, refunded_amount_cents: 1000)
    captured = insert(:booking_payment, paid_at: now)
    unpaid = insert(:booking_payment, paid_at: nil)
    untouched = insert(:booking_payment, status: :disputed, paid_at: now)

    MigrationRunner.down!(@version)
    Enum.each([refunded, partial, captured, unpaid], &set_raw_status!(&1.id, "requires_action"))

    MigrationRunner.up!(@version)

    assert Repo.reload!(refunded).status == :refunded
    assert Repo.reload!(partial).status == :partially_refunded
    assert Repo.reload!(captured).status == :paid
    assert Repo.reload!(unpaid).status == :failed
    assert Repo.reload!(untouched).status == :disputed

    assert_raise Postgrex.Error, ~r/booking_payments_status_must_be_known/, fn ->
      set_raw_status!(untouched.id, "requires_action")
    end
  end

  defp set_raw_status!(id, status) do
    Repo.query!("UPDATE booking_payments SET status = $1 WHERE id = $2", [
      status,
      UUID.dump!(id)
    ])
  end
end
