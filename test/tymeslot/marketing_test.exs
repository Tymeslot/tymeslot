defmodule Tymeslot.MarketingTest do
  use Tymeslot.DataCase, async: true

  @moduletag :marketing

  alias Tymeslot.Marketing

  import Tymeslot.Factory

  describe "unsubscribed?/1" do
    test "returns false for a freshly inserted user" do
      user = insert(:user)
      refute Marketing.unsubscribed?(user)
    end

    test "returns true once the timestamp is set" do
      user = insert(:user, marketing_unsubscribed_at: DateTime.utc_now(:second))
      assert Marketing.unsubscribed?(user)
    end
  end

  describe "unsubscribe/1 and resubscribe/1" do
    test "unsubscribe sets the timestamp" do
      user = insert(:user)

      assert {:ok, unsubscribed} = Marketing.unsubscribe(user)
      assert Marketing.unsubscribed?(unsubscribed)
    end

    test "unsubscribe is idempotent — calling twice keeps the user unsubscribed" do
      user = insert(:user)

      {:ok, first} = Marketing.unsubscribe(user)
      {:ok, second} = Marketing.unsubscribe(first)

      assert Marketing.unsubscribed?(second)
      assert second.marketing_unsubscribed_at == first.marketing_unsubscribed_at
    end

    test "resubscribe clears the timestamp" do
      user = insert(:user, marketing_unsubscribed_at: DateTime.utc_now(:second))

      assert {:ok, resubscribed} = Marketing.resubscribe(user)
      refute Marketing.unsubscribed?(resubscribed)
    end

    test "resubscribe is idempotent — calling twice on an already-subscribed user succeeds" do
      user = insert(:user)

      {:ok, first} = Marketing.resubscribe(user)
      refute Marketing.unsubscribed?(first)

      {:ok, second} = Marketing.resubscribe(first)
      refute Marketing.unsubscribed?(second)
    end
  end

  describe "list_eligible_user_ids/0 and count_eligible_user_ids/0" do
    test "include verified, subscribed users and exclude unverified or unsubscribed ones" do
      eligible = insert(:user, verified_at: DateTime.utc_now(:second))
      _unverified = insert(:user, verified_at: nil)

      _unsubscribed =
        insert(:user,
          verified_at: DateTime.utc_now(:second),
          marketing_unsubscribed_at: DateTime.utc_now(:second)
        )

      ids = Marketing.list_eligible_user_ids()

      assert eligible.id in ids
      assert Marketing.count_eligible_user_ids() == length(ids)
    end
  end
end
