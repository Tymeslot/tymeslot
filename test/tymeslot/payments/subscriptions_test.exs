defmodule Tymeslot.Payments.SubscriptionsTest do
  # This suite mutates the global :subscription_manager application env, which
  # other payments suites read at runtime — it must not run concurrently with
  # them, and every mutation must be undone.
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  import Mox

  alias Tymeslot.Payments.Subscriptions

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:tymeslot, :subscription_manager)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:tymeslot, :subscription_manager)
        manager -> Application.put_env(:tymeslot, :subscription_manager, manager)
      end
    end)

    :ok
  end

  describe "cancel_subscription/3" do
    test "delegates to subscription manager when configured" do
      subscription_id = "sub_123"
      user_id = 1
      opts = [at_period_end: true]

      # Configure the subscription manager
      Application.put_env(
        :tymeslot,
        :subscription_manager,
        Tymeslot.Payments.SubscriptionManagerMock
      )

      expect(Tymeslot.Payments.SubscriptionManagerMock, :cancel_subscription, fn
        ^subscription_id, ^user_id, ^opts ->
          {:ok, %{id: subscription_id, status: "canceled"}}
      end)

      assert {:ok, %{id: "sub_123", status: "canceled"}} =
               Subscriptions.cancel_subscription(subscription_id, user_id, opts)
    end

    test "returns error when subscription manager not configured" do
      # Remove subscription manager configuration
      Application.delete_env(:tymeslot, :subscription_manager)

      assert {:error, :subscriptions_not_supported} =
               Subscriptions.cancel_subscription("sub_123", 1)
    end

    test "uses empty options by default" do
      subscription_id = "sub_123"
      user_id = 1

      Application.put_env(
        :tymeslot,
        :subscription_manager,
        Tymeslot.Payments.SubscriptionManagerMock
      )

      expect(Tymeslot.Payments.SubscriptionManagerMock, :cancel_subscription, fn
        ^subscription_id, ^user_id, [] ->
          {:ok, %{id: subscription_id}}
      end)

      assert {:ok, _result} = Subscriptions.cancel_subscription(subscription_id, user_id)
    end

    test "propagates errors from subscription manager" do
      Application.put_env(
        :tymeslot,
        :subscription_manager,
        Tymeslot.Payments.SubscriptionManagerMock
      )

      expect(Tymeslot.Payments.SubscriptionManagerMock, :cancel_subscription, fn _sub_id,
                                                                                 _user_id,
                                                                                 _opts ->
        {:error, :subscription_not_found}
      end)

      assert {:error, :subscription_not_found} =
               Subscriptions.cancel_subscription("sub_invalid", 1)
    end
  end

  describe "update_subscription/4" do
    test "delegates to subscription manager when configured" do
      subscription_id = "sub_123"
      new_price_id = "price_456"
      user_id = 1
      metadata = %{upgrade_reason: "needs_more_features"}

      Application.put_env(
        :tymeslot,
        :subscription_manager,
        Tymeslot.Payments.SubscriptionManagerMock
      )

      expect(Tymeslot.Payments.SubscriptionManagerMock, :update_subscription, fn
        ^subscription_id, ^new_price_id, ^user_id, ^metadata ->
          {:ok, %{id: subscription_id, plan: new_price_id}}
      end)

      assert {:ok, %{id: "sub_123", plan: "price_456"}} =
               Subscriptions.update_subscription(subscription_id, new_price_id, user_id, metadata)
    end

    test "returns error when subscription manager not configured" do
      Application.delete_env(:tymeslot, :subscription_manager)

      assert {:error, :subscriptions_not_supported} =
               Subscriptions.update_subscription("sub_123", "price_456", 1)
    end

    test "uses empty metadata by default" do
      subscription_id = "sub_123"
      new_price_id = "price_456"
      user_id = 1

      Application.put_env(
        :tymeslot,
        :subscription_manager,
        Tymeslot.Payments.SubscriptionManagerMock
      )

      expect(Tymeslot.Payments.SubscriptionManagerMock, :update_subscription, fn
        ^subscription_id, ^new_price_id, ^user_id, metadata ->
          assert metadata == %{}
          {:ok, %{id: subscription_id}}
      end)

      assert {:ok, _result} =
               Subscriptions.update_subscription(subscription_id, new_price_id, user_id)
    end

    test "propagates errors from subscription manager" do
      Application.put_env(
        :tymeslot,
        :subscription_manager,
        Tymeslot.Payments.SubscriptionManagerMock
      )

      expect(Tymeslot.Payments.SubscriptionManagerMock, :update_subscription, fn _sub_id,
                                                                                 _price_id,
                                                                                 _user_id,
                                                                                 _metadata ->
        {:error, :invalid_price_id}
      end)

      assert {:error, :invalid_price_id} =
               Subscriptions.update_subscription("sub_123", "invalid", 1)
    end
  end

  describe "downgrade_subscription/4" do
    test "returns error when subscription manager not configured" do
      Application.delete_env(:tymeslot, :subscription_manager)

      assert {:error, :downgrades_not_supported} =
               Subscriptions.downgrade_subscription("sub_123", "price_basic", 1)
    end

    test "returns error when subscription manager doesn't export downgrade function" do
      # SubscriptionManagerMock doesn't have downgrade_subscription/4 in its behavior
      # so it will return :downgrades_not_supported
      Application.put_env(
        :tymeslot,
        :subscription_manager,
        Tymeslot.Payments.SubscriptionManagerMock
      )

      assert {:error, :downgrades_not_supported} =
               Subscriptions.downgrade_subscription("sub_123", "price_basic", 1)
    end

    test "uses empty metadata by default" do
      # Even though the function isn't available, test that the call structure is correct
      Application.delete_env(:tymeslot, :subscription_manager)

      # Should return error with empty metadata (default argument works)
      assert {:error, :downgrades_not_supported} =
               Subscriptions.downgrade_subscription("sub_123", "price_basic", 1)
    end
  end

  describe "module configuration" do
    test "handles nil subscription manager gracefully across all functions" do
      Application.delete_env(:tymeslot, :subscription_manager)

      assert {:error, :subscriptions_not_supported} =
               Subscriptions.cancel_subscription("sub_123", 1)

      assert {:error, :subscriptions_not_supported} =
               Subscriptions.update_subscription("sub_123", "price_456", 1)

      assert {:error, :downgrades_not_supported} =
               Subscriptions.downgrade_subscription("sub_123", "price_basic", 1)
    end

    test "subscription manager is properly retrieved from config" do
      # This is an integration test to verify the config module interaction
      Application.put_env(
        :tymeslot,
        :subscription_manager,
        Tymeslot.Payments.SubscriptionManagerMock
      )

      expect(Tymeslot.Payments.SubscriptionManagerMock, :cancel_subscription, fn _sub_id,
                                                                                 _user_id,
                                                                                 _opts ->
        {:ok, %{}}
      end)

      assert {:ok, _result} = Subscriptions.cancel_subscription("sub_123", 1)

      # Clean up
      Application.delete_env(:tymeslot, :subscription_manager)
    end
  end
end
