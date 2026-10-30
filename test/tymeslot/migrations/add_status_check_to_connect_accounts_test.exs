defmodule Tymeslot.Migrations.AddStatusCheckToConnectAccountsTest do
  @moduledoc """
  Verifies `20261029110335_add_status_check_to_connect_accounts` backfills an
  out-of-vocabulary `status` from the row's own facts (soft-deleted, holding a
  Stripe account, or neither), leaves known values alone, and then closes the
  column with a CHECK constraint.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :database
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_029_110_335

  test "derives a known status for each stray row and re-closes the constraint" do
    deleted = insert(:connect_account, user: nil, deleted_at: DateTime.utc_now(:second))
    linked = insert(:connect_account, user: insert(:user))
    placeholder = insert(:connect_account, user: insert(:user), stripe_account_id: nil)
    untouched = insert(:connect_account, user: insert(:user), status: :creating)

    MigrationRunner.down!(@version)
    Enum.each([deleted, linked, placeholder], &set_raw_status!(&1.id, "suspended"))

    MigrationRunner.up!(@version)

    assert Repo.reload!(deleted).status == :deleted
    assert Repo.reload!(linked).status == :active
    assert Repo.reload!(placeholder).status == :creating
    assert Repo.reload!(untouched).status == :creating

    assert_raise Postgrex.Error, ~r/connect_accounts_status_must_be_known/, fn ->
      set_raw_status!(untouched.id, "suspended")
    end
  end

  defp set_raw_status!(id, status) do
    Repo.query!("UPDATE connect_accounts SET status = $1 WHERE id = $2", [
      status,
      UUID.dump!(id)
    ])
  end
end
