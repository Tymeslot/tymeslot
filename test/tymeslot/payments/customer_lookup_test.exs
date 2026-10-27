defmodule Tymeslot.Payments.CustomerLookupTest do
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  import Mox

  alias Tymeslot.Payments.CustomerLookup
  alias Tymeslot.Payments.SubscriptionManagerMock
  alias Tymeslot.PaymentTestHelpers
  alias Tymeslot.TestFixtures

  setup :verify_on_exit!

  # A subscription manager written before the lookup callbacks existed.
  defmodule ManagerWithoutLookups do
    @spec should_show_branding?(integer()) :: boolean()
    def should_show_branding?(_user_id), do: true
  end

  # Core standalone: no subscription manager, so every lookup below the
  # metadata goes to `payment_transactions`. The describe blocks that consult
  # a manager configure the mock themselves.
  setup do
    original = Application.get_env(:tymeslot, :subscription_manager)
    Application.put_env(:tymeslot, :subscription_manager, nil)
    on_exit(fn -> Application.put_env(:tymeslot, :subscription_manager, original) end)
    :ok
  end

  describe "parse_user_id/1" do
    test "parses integer" do
      assert CustomerLookup.parse_user_id(123) == 123
    end

    test "parses string integer" do
      assert CustomerLookup.parse_user_id("456") == 456
    end

    test "returns nil for invalid string" do
      assert CustomerLookup.parse_user_id("abc") == nil
    end

    test "returns nil for nil" do
      assert CustomerLookup.parse_user_id(nil) == nil
    end

    test "returns nil for other types" do
      assert CustomerLookup.parse_user_id(%{id: 1}) == nil
    end
  end

  describe "subscription lookups" do
    test "answer nil for a nil id" do
      assert CustomerLookup.get_subscription_by_customer_id(nil) == nil
      assert CustomerLookup.get_subscription_by_subscription_id(nil) == nil
    end

    test "answer nil without a subscription manager, as Core standalone" do
      assert CustomerLookup.get_subscription_by_customer_id("cus_test") == nil
      assert CustomerLookup.get_subscription_by_subscription_id("sub_test") == nil
    end

    test "answer nil from a manager that does not implement them" do
      Application.put_env(:tymeslot, :subscription_manager, ManagerWithoutLookups)

      assert CustomerLookup.get_subscription_by_customer_id("cus_test") == nil
      assert CustomerLookup.get_subscription_by_subscription_id("sub_test") == nil
    end

    test "ask the configured subscription manager" do
      Application.put_env(:tymeslot, :subscription_manager, SubscriptionManagerMock)

      expect(SubscriptionManagerMock, :get_subscription_by_customer_id, fn "cus_known" ->
        %{user_id: 7}
      end)

      expect(SubscriptionManagerMock, :get_subscription_by_subscription_id, fn "sub_known" ->
        %{user_id: 8}
      end)

      assert CustomerLookup.get_subscription_by_customer_id("cus_known") == %{user_id: 7}
      assert CustomerLookup.get_subscription_by_subscription_id("sub_known") == %{user_id: 8}
    end
  end

  describe "find_user_id/1" do
    # With no subscription manager every case below exercises the
    # `payment_transactions` fallback, the path Core standalone runs; the
    # last one shows a manager's record taking precedence over it.
    test "returns nil when nothing resolves" do
      assert CustomerLookup.find_user_id(%{subscription_id: nil, customer_id: nil}) == nil

      assert CustomerLookup.find_user_id(%{
               subscription_id: "sub_missing",
               customer_id: "cus_missing"
             }) == nil
    end

    test "falls back to the completed transaction for the same subscription" do
      user = TestFixtures.create_user_fixture()

      PaymentTestHelpers.create_test_transaction(%{
        user_id: user.id,
        status: "completed",
        subscription_id: "sub_fallback",
        stripe_id: "sess_fallback"
      })

      assert CustomerLookup.find_user_id(%{
               subscription_id: "sub_fallback",
               customer_id: "cus_unrelated"
             }) == user.id
    end

    test "falls back to the completed transaction for the same Stripe customer when the subscription doesn't match" do
      user = TestFixtures.create_user_fixture()

      PaymentTestHelpers.create_test_transaction(%{
        user_id: user.id,
        status: "completed",
        stripe_id: "sess_customer_fallback",
        stripe_customer_id: "cus_customer_fallback"
      })

      assert CustomerLookup.find_user_id(%{
               subscription_id: "sub_never_created_locally",
               customer_id: "cus_customer_fallback"
             }) == user.id
    end

    test "ignores pending and failed transactions: they are not an ownership signal" do
      user = TestFixtures.create_user_fixture()

      PaymentTestHelpers.create_test_transaction(%{
        user_id: user.id,
        status: "pending",
        subscription_id: "sub_pending",
        stripe_id: "sess_pending",
        stripe_customer_id: "cus_pending"
      })

      assert CustomerLookup.find_user_id(%{
               subscription_id: "sub_pending",
               customer_id: "cus_pending"
             }) == nil
    end

    test "prefers the subscription match over the customer match" do
      subscription_owner = TestFixtures.create_user_fixture()
      customer_owner = TestFixtures.create_user_fixture()

      PaymentTestHelpers.create_test_transaction(%{
        user_id: subscription_owner.id,
        status: "completed",
        subscription_id: "sub_priority",
        stripe_id: "sess_priority_sub",
        stripe_customer_id: "cus_priority"
      })

      PaymentTestHelpers.create_test_transaction(%{
        user_id: customer_owner.id,
        status: "completed",
        stripe_id: "sess_priority_cus",
        stripe_customer_id: "cus_priority"
      })

      assert CustomerLookup.find_user_id(%{
               subscription_id: "sub_priority",
               customer_id: "cus_priority"
             }) == subscription_owner.id
    end

    test "prefers metadata_user_id over every database fallback" do
      metadata_owner = TestFixtures.create_user_fixture()
      transaction_owner = TestFixtures.create_user_fixture()

      PaymentTestHelpers.create_test_transaction(%{
        user_id: transaction_owner.id,
        status: "completed",
        subscription_id: "sub_metadata_priority",
        stripe_id: "sess_metadata_priority",
        stripe_customer_id: "cus_metadata_priority"
      })

      assert CustomerLookup.find_user_id(%{
               subscription_id: "sub_metadata_priority",
               customer_id: "cus_metadata_priority",
               metadata_user_id: metadata_owner.id
             }) == metadata_owner.id
    end

    test "falls back to the database lookups when metadata_user_id is nil" do
      user = TestFixtures.create_user_fixture()

      PaymentTestHelpers.create_test_transaction(%{
        user_id: user.id,
        status: "completed",
        subscription_id: "sub_metadata_fallback",
        stripe_id: "sess_metadata_fallback"
      })

      assert CustomerLookup.find_user_id(%{
               subscription_id: "sub_metadata_fallback",
               customer_id: "cus_unrelated",
               metadata_user_id: nil
             }) == user.id
    end

    test "falls back to the database lookups when metadata_user_id is absent from the map" do
      user = TestFixtures.create_user_fixture()

      PaymentTestHelpers.create_test_transaction(%{
        user_id: user.id,
        status: "completed",
        subscription_id: "sub_metadata_absent",
        stripe_id: "sess_metadata_absent"
      })

      assert CustomerLookup.find_user_id(%{
               subscription_id: "sub_metadata_absent",
               customer_id: "cus_unrelated"
             }) == user.id
    end

    test "prefers the subscription manager's record over the transaction fallback" do
      manager_owner = TestFixtures.create_user_fixture()
      transaction_owner = TestFixtures.create_user_fixture()

      PaymentTestHelpers.create_test_transaction(%{
        user_id: transaction_owner.id,
        status: "completed",
        subscription_id: "sub_managed",
        stripe_id: "sess_managed"
      })

      Application.put_env(:tymeslot, :subscription_manager, SubscriptionManagerMock)

      stub(SubscriptionManagerMock, :get_subscription_by_subscription_id, fn "sub_managed" ->
        %{user_id: manager_owner.id}
      end)

      assert CustomerLookup.find_user_id(%{subscription_id: "sub_managed", customer_id: nil}) ==
               manager_owner.id
    end
  end
end
