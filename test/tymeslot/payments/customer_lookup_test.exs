defmodule Tymeslot.Payments.CustomerLookupTest do
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  alias Tymeslot.Payments.CustomerLookup
  alias Tymeslot.PaymentTestHelpers
  alias Tymeslot.TestFixtures

  setup do
    # Configure subscription schema for tests
    Application.put_env(:tymeslot, :subscription_schema, TymeslotSaas.Payments.SubscriptionSchema)
    Application.put_env(:tymeslot, :repo, Tymeslot.SaasRepo)

    on_exit(fn ->
      Application.delete_env(:tymeslot, :subscription_schema)
      Application.delete_env(:tymeslot, :repo)
    end)

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

  # find_user_id_by_stripe_customer has been moved to TymeslotSaas.Payments.CustomerLookup
  # Tests for that function are now in the SaaS test suite

  describe "get_subscription_by_customer_id/1" do
    test "returns nil when stripe_customer_id is nil" do
      assert CustomerLookup.get_subscription_by_customer_id(nil) == nil
    end

    test "returns nil when subscription schema not configured" do
      Application.delete_env(:tymeslot, :subscription_schema)

      assert CustomerLookup.get_subscription_by_customer_id("cus_test") == nil

      # Restore for other tests
      Application.put_env(
        :tymeslot,
        :subscription_schema,
        TymeslotSaas.Payments.SubscriptionSchema
      )
    end

    # Note: Full integration tests with SaaS schema are in the SaaS test suite
    # This test suite focuses on Core standalone behavior
    test "returns nil when subscription schema not configured and logs appropriately" do
      Application.delete_env(:tymeslot, :subscription_schema)

      # Should return nil when schema not configured
      assert CustomerLookup.get_subscription_by_customer_id("cus_123") == nil

      # Restore for other tests
      Application.put_env(
        :tymeslot,
        :subscription_schema,
        TymeslotSaas.Payments.SubscriptionSchema
      )
    end
  end

  describe "get_subscription_by_subscription_id/1" do
    test "returns nil when stripe_subscription_id is nil" do
      assert CustomerLookup.get_subscription_by_subscription_id(nil) == nil
    end

    test "returns nil when subscription schema not configured" do
      Application.delete_env(:tymeslot, :subscription_schema)

      assert CustomerLookup.get_subscription_by_subscription_id("sub_test") == nil
    end
  end

  describe "find_user_id/1" do
    # `TymeslotSaas.Payments.SubscriptionSchema` is not loaded in Core's own
    # test suite (Core never depends on SaaS), so `Code.ensure_loaded?/1`
    # always fails here and every case below exercises the
    # `payment_transactions` fallback — the path Core standalone actually
    # runs. SaaS's test suite covers the subscription_schema-first path.
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
  end
end
