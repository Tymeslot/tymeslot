defmodule Tymeslot.Payments.Webhooks.StandaloneHandlerTest do
  use ExUnit.Case, async: false
  @moduletag :payments

  alias Ecto.Adapters.SQL.Sandbox
  alias Tymeslot.Payments.SubscriptionManagerMock
  alias Tymeslot.Payments.Webhooks.DisputeHandler
  alias Tymeslot.Payments.Webhooks.RefundHandler
  alias Tymeslot.Payments.Webhooks.TrialWillEndHandler
  alias Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    # Ensure we are in standalone-like config for these tests
    original_manager = Application.get_env(:tymeslot, :subscription_manager)
    # Standalone: no subscription manager at all, so subscription lookups
    # answer nil and the handlers take their standalone paths.
    Application.put_env(:tymeslot, :subscription_manager, nil)

    # Checkout Repo for database access
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    on_exit(fn ->
      Application.put_env(:tymeslot, :subscription_manager, original_manager)
    end)

    :ok
  end

  defmodule TestSubscriptionSchema do
    defstruct [:user_id]
  end

  # A subscription manager that records a subscription for `user_id` under any
  # id. The module setup restores the standalone (nil) manager afterwards.
  defp stub_recorded_subscription(user_id) do
    Application.put_env(:tymeslot, :subscription_manager, SubscriptionManagerMock)
    subscription = %TestSubscriptionSchema{user_id: user_id}
    stub(SubscriptionManagerMock, :get_subscription_by_customer_id, fn _id -> subscription end)

    stub(SubscriptionManagerMock, :get_subscription_by_subscription_id, fn _id -> subscription end)
  end

  defp with_object(event, object), do: Map.put(event, "data", %{"object" => object})

  defp setup_test_configs(user) do
    original_provider = Application.get_env(:tymeslot, :stripe_provider)

    Application.put_env(:tymeslot, :stripe_provider, Tymeslot.Payments.StripeMock)
    stub_recorded_subscription(user.id)

    on_exit(fn ->
      Application.put_env(:tymeslot, :stripe_provider, original_provider)
    end)
  end

  describe "RefundHandler standalone" do
    test "logs refund events in standalone mode" do
      charge = %{
        "id" => "ch_standalone_test",
        "customer" => "cus_standalone",
        "amount_refunded" => 500,
        "refunds" => %{"data" => [%{"amount" => 500}]}
      }

      event = %{"type" => "charge.refunded", "id" => "evt_123"}

      assert {:ok, :refund_logged} = RefundHandler.handle(with_object(event, charge))
    end

    test "accepts refund events even when refund details are missing" do
      charge = %{
        "id" => "ch_standalone_missing_refunds",
        "customer" => "cus_standalone",
        "amount_refunded" => 750
      }

      event = %{"type" => "charge.refunded", "id" => "evt_124"}

      assert {:ok, :refund_logged} = RefundHandler.handle(with_object(event, charge))
    end

    test "acknowledges refund status updates" do
      refund = %{"id" => "re_123", "status" => "succeeded"}
      event = %{"type" => "charge.refund.updated", "id" => "evt_125"}

      assert {:ok, :refund_status_updated} = RefundHandler.handle(with_object(event, refund))
    end
  end

  describe "TrialWillEndHandler standalone" do
    test "acknowledges trial ending events in standalone mode" do
      trial_end = DateTime.add(DateTime.utc_now(), 3, :day)

      event = %{
        "type" => "customer.subscription.trial_will_end",
        "data" => %{
          "object" => %{
            "id" => "sub_standalone",
            "customer" => "cus_standalone",
            "trial_end" => DateTime.to_unix(trial_end)
          }
        }
      }

      assert {:ok, :subscription_not_found} =
               TrialWillEndHandler.handle(event)
    end

    test "rejects trial ending events with invalid timestamps" do
      event = %{
        "type" => "customer.subscription.trial_will_end",
        "data" => %{
          "object" => %{
            "id" => "sub_standalone",
            "customer" => "cus_standalone",
            "trial_end" => "not_a_timestamp"
          }
        }
      }

      assert {:error, :permanent, :invalid_timestamp} = TrialWillEndHandler.handle(event)
    end

    test "processes trial ending events when subscription exists" do
      stub_recorded_subscription(insert(:user).id)

      trial_end = DateTime.add(DateTime.utc_now(), 2, :day)

      event = %{
        "type" => "customer.subscription.trial_will_end",
        "data" => %{
          "object" => %{
            "id" => "sub_existing",
            "customer" => "cus_existing",
            "trial_end" => DateTime.to_unix(trial_end)
          }
        }
      }

      assert {:ok, :trial_ending_notified} =
               TrialWillEndHandler.handle(event)
    end
  end

  describe "DisputeHandler standalone" do
    test "requests retry when Stripe is unavailable" do
      dispute = %{
        "id" => "dp_123",
        "charge" => "ch_error",
        "amount" => 1000,
        "reason" => "fraudulent",
        "status" => "needs_response"
      }

      event = %{"type" => "charge.dispute.created"}

      # Mock Stripe provider to return error
      original_provider = Application.get_env(:tymeslot, :stripe_provider)
      Application.put_env(:tymeslot, :stripe_provider, Tymeslot.Payments.StripeMock)

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn "ch_error" ->
        {:error, %{message: "Stripe API is down"}}
      end)

      try do
        assert {:error, :retry_later, _reason} =
                 DisputeHandler.handle(with_object(event, dispute))
      after
        Application.put_env(:tymeslot, :stripe_provider, original_provider)
      end
    end

    test "processes disputes even when evidence details are missing" do
      user = insert(:user)
      setup_test_configs(user)

      _transaction =
        insert(:payment_transaction,
          user: user,
          status: "completed",
          stripe_customer_id: "cus_123",
          subscription_id: nil
        )

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn "ch_123" ->
        {:ok, %{"customer" => "cus_123"}}
      end)

      dispute = %{
        "id" => "dp_456",
        "charge" => "ch_123",
        "amount" => 1000,
        "reason" => "fraudulent",
        "status" => "needs_response"
      }

      event = %{"type" => "charge.dispute.created"}

      assert {:ok, :dispute_created} = DisputeHandler.handle(with_object(event, dispute))
    end

    test "processes disputes with invalid evidence due dates" do
      user = insert(:user)
      setup_test_configs(user)

      _transaction =
        insert(:payment_transaction,
          user: user,
          status: "completed",
          stripe_customer_id: "cus_456",
          subscription_id: nil
        )

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn "ch_456" ->
        {:ok, %{"customer" => "cus_456"}}
      end)

      dispute = %{
        "id" => "dp_789",
        "charge" => "ch_456",
        "amount" => 1500,
        "reason" => "duplicate",
        "status" => "needs_response",
        "evidence_details" => %{"due_by" => "invalid"}
      }

      event = %{"type" => "charge.dispute.created"}

      assert {:ok, :dispute_created} = DisputeHandler.handle(with_object(event, dispute))
    end
  end
end
