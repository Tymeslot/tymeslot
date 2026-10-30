defmodule Tymeslot.Migrations.AddStatusCheckToPaymentTransactionsTest do
  @moduledoc """
  Verifies `20261029105904_add_status_check_to_payment_transactions` backfills
  an out-of-vocabulary `status` to `failed`, leaves known values alone, and
  then closes the column with a CHECK constraint, so a row `Ecto.Enum` cannot
  load can no longer be written.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :database
  @moduletag :migrations

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_029_105_904

  test "backfills an unknown status to failed and re-closes the constraint" do
    user = insert(:user)
    stray = insert(:payment_transaction, user: user, status: :completed)
    known = insert(:payment_transaction, user: insert(:user), status: :pending)

    MigrationRunner.down!(@version)
    set_raw_status!(stray.id, "refunded")

    MigrationRunner.up!(@version)

    assert Repo.reload!(stray).status == :failed
    assert Repo.reload!(known).status == :pending

    assert_raise Postgrex.Error, ~r/payment_transactions_status_must_be_known/, fn ->
      set_raw_status!(known.id, "refunded")
    end
  end

  defp set_raw_status!(id, status) do
    Repo.query!("UPDATE payment_transactions SET status = $1 WHERE id = $2", [status, id])
  end
end
