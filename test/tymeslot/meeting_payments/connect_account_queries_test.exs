defmodule Tymeslot.MeetingPayments.ConnectAccountQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :payments

  alias Tymeslot.MeetingPayments.ConnectAccountQueries

  test "live_for_user returns active row" do
    user = insert(:user)
    {:ok, _account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")
    assert account = ConnectAccountQueries.live_for_user(user.id)
    assert account.status == "creating"
  end

  test "live_for_user excludes soft-deleted rows" do
    user = insert(:user)
    {:ok, _account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")
    now = DateTime.utc_now(:second)
    ConnectAccountQueries.soft_delete_for_user(user.id, now)
    refute ConnectAccountQueries.live_for_user(user.id)
  end

  test "soft_delete sets deleted_at and nilifies user_id" do
    user = insert(:user)
    {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")
    now = DateTime.utc_now(:second)
    ConnectAccountQueries.soft_delete_for_user(user.id, now)

    deleted = Repo.reload(account)
    assert deleted.deleted_at == now
    assert deleted.user_id == nil
    assert deleted.status == "deleted"
    refute deleted.charges_enabled
  end

  test "by_stripe_account_id finds row" do
    user = insert(:user)
    {:ok, _account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

    live = ConnectAccountQueries.live_for_user(user.id)
    {:ok, account} = ConnectAccountQueries.update(live, %{stripe_account_id: "acct_xyz"})

    assert found = ConnectAccountQueries.by_stripe_account_id("acct_xyz")
    assert found.id == account.id
  end

  test "by_stripe_account_id excludes soft-deleted rows" do
    user = insert(:user)
    {:ok, account} = ConnectAccountQueries.insert_placeholder(user.id, "ch")
    {:ok, _updated} = ConnectAccountQueries.update(account, %{stripe_account_id: "acct_soft_del"})

    now = DateTime.utc_now(:second)
    ConnectAccountQueries.soft_delete_for_user(user.id, now)

    refute ConnectAccountQueries.by_stripe_account_id("acct_soft_del")
  end

  test "insert_placeholder returns unique-constraint error on duplicate live row" do
    user = insert(:user)
    assert {:ok, _first} = ConnectAccountQueries.insert_placeholder(user.id, "ch")

    # Second insert for the same user must hit the partial unique index and
    # surface a changeset error rather than crashing or silently inserting.
    assert {:error, changeset} = ConnectAccountQueries.insert_placeholder(user.id, "de")
    assert {"has already been taken", _opts} = changeset.errors[:user_id]
  end
end
