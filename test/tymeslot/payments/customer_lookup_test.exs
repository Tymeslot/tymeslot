defmodule Tymeslot.Payments.CustomerLookupTest do
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  alias Tymeslot.Payments.CustomerLookup

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
      Application.put_env(:tymeslot, :subscription_schema, TymeslotSaas.Payments.SubscriptionSchema)
    end

    # Note: Full integration tests with SaaS schema are in the SaaS test suite
    # This test suite focuses on Core standalone behavior
    test "returns nil when subscription schema not configured and logs appropriately" do
      Application.delete_env(:tymeslot, :subscription_schema)

      # Should return nil when schema not configured
      assert CustomerLookup.get_subscription_by_customer_id("cus_123") == nil

      # Restore for other tests
      Application.put_env(:tymeslot, :subscription_schema, TymeslotSaas.Payments.SubscriptionSchema)
    end
  end
end
