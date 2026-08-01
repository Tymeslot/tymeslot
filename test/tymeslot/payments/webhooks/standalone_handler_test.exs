defmodule Tymeslot.Payments.Webhooks.StandaloneHandlerTest do
  use ExUnit.Case, async: false
  @moduletag :payments

  alias Ecto.Adapters.SQL.Sandbox
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
    original_repo = Application.get_env(:tymeslot, :repo)
    Application.put_env(:tymeslot, :repo, Repo)

    # Checkout Repo for database access
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    on_exit(fn ->
      Application.put_env(:tymeslot, :repo, original_repo)
    end)

    :ok
  end

  defmodule TestSubscriptionSchema do
    defstruct [:user_id]
  end

  defmodule TestUser do
    defstruct [:id, :email, :name]
  end

  defmodule TestRepo do
    @spec get_by(any(), any()) ::
            Tymeslot.Payments.Webhooks.StandaloneHandlerTest.TestSubscriptionSchema
    def get_by(_schema, _attrs),
      do: %Tymeslot.Payments.Webhooks.StandaloneHandlerTest.TestSubscriptionSchema{user_id: 123}

    @spec get(any(), any()) :: Tymeslot.Payments.Webhooks.StandaloneHandlerTest.TestUser
    def get(_schema, _id),
      do: %Tymeslot.Payments.Webhooks.StandaloneHandlerTest.TestUser{
        id: 123,
        email: "test@example.com",
        name: "Test User"
      }

    # `deliver_user_email/5` preloads `:profile` before handing the user to a
    # template. This stub's user carries its name directly, so there is nothing
    # to load.
    @spec preload(any(), any()) :: Tymeslot.Payments.Webhooks.StandaloneHandlerTest.TestUser
    def preload(user, _assoc), do: user
  end

  defp setup_test_configs do
    original_repo = Application.get_env(:tymeslot, :repo)
    original_schema = Application.get_env(:tymeslot, :subscription_schema)
    original_provider = Application.get_env(:tymeslot, :stripe_provider)

    Application.put_env(:tymeslot, :repo, TestRepo)
    Application.put_env(:tymeslot, :subscription_schema, TestSubscriptionSchema)
    Application.put_env(:tymeslot, :stripe_provider, Tymeslot.Payments.StripeMock)

    on_exit(fn ->
      Application.put_env(:tymeslot, :repo, original_repo)
      Application.put_env(:tymeslot, :subscription_schema, original_schema)
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

      assert {:ok, :refund_logged} = RefundHandler.process(event, charge)
    end

    test "accepts refund events even when refund details are missing" do
      charge = %{
        "id" => "ch_standalone_missing_refunds",
        "customer" => "cus_standalone",
        "amount_refunded" => 750
      }

      event = %{"type" => "charge.refunded", "id" => "evt_124"}

      assert {:ok, :refund_logged} = RefundHandler.process(event, charge)
    end

    test "acknowledges refund status updates" do
      refund = %{"id" => "re_123", "status" => "succeeded"}
      event = %{"type" => "charge.refund.updated", "id" => "evt_125"}

      assert {:ok, :refund_status_updated} = RefundHandler.process(event, refund)
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
               TrialWillEndHandler.process(event, event["data"]["object"])
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

      assert {:error, :invalid_timestamp} =
               TrialWillEndHandler.process(event, event["data"]["object"])
    end

    test "processes trial ending events when subscription exists" do
      original_repo = Application.get_env(:tymeslot, :repo)
      original_schema = Application.get_env(:tymeslot, :subscription_schema)

      Application.put_env(:tymeslot, :repo, TestRepo)
      Application.put_env(:tymeslot, :subscription_schema, TestSubscriptionSchema)

      on_exit(fn ->
        Application.put_env(:tymeslot, :repo, original_repo)
        Application.put_env(:tymeslot, :subscription_schema, original_schema)
      end)

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
               TrialWillEndHandler.process(event, event["data"]["object"])
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
        assert {:error, :retry_later, _reason} = DisputeHandler.process(event, dispute)
      after
        Application.put_env(:tymeslot, :stripe_provider, original_provider)
      end
    end

    test "processes disputes even when evidence details are missing" do
      setup_test_configs()
      user = insert(:user)

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

      assert {:ok, :dispute_created} = DisputeHandler.process(event, dispute)
    end

    test "processes disputes with invalid evidence due dates" do
      setup_test_configs()
      user = insert(:user)

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

      assert {:ok, :dispute_created} = DisputeHandler.process(event, dispute)
    end
  end
end
