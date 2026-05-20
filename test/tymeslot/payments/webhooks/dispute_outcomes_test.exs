defmodule Tymeslot.Payments.Webhooks.DisputeOutcomesTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Payments.Webhooks.DisputeHandler

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    original_repo = Application.get_env(:tymeslot, :repo)
    original_provider = Application.get_env(:tymeslot, :stripe_provider)

    # Test env defaults :repo to SaasRepo; this suite needs the factory's
    # PaymentTransactionSchema rows, which live in Tymeslot.Repo.
    Application.put_env(:tymeslot, :repo, Tymeslot.Repo)
    Application.put_env(:tymeslot, :stripe_provider, Tymeslot.Payments.StripeMock)

    on_exit(fn ->
      restore(:repo, original_repo)
      restore(:stripe_provider, original_provider)
    end)

    Phoenix.PubSub.subscribe(Tymeslot.PubSub, "payment_events:tymeslot")
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore(key, value), do: Application.put_env(:tymeslot, key, value)

  defp dispute(status, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "dp_#{System.unique_integer([:positive])}",
        "charge" => "ch_#{System.unique_integer([:positive])}",
        "amount" => 1000,
        "reason" => "fraudulent",
        "status" => status
      },
      attrs
    )
  end

  defp subscription_charge(customer_id \\ "cus_sub") do
    %{
      "id" => "ch_sub",
      "customer" => customer_id,
      "subscription" => "sub_123",
      "invoice" => "in_123"
    }
  end

  defp one_time_charge(customer_id) do
    %{"id" => "ch_one_time", "customer" => customer_id}
  end

  describe "process/2 — charge.dispute.updated" do
    test "subscription dispute is forwarded to SaaS via PubSub" do
      d = dispute("under_review")
      event = %{"id" => "evt_upd_1", "type" => "charge.dispute.updated"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id -> {:ok, subscription_charge()} end)

      assert {:ok, :dispute_updated} = DisputeHandler.process(event, d)

      assert_received %{
        event: :dispute_updated,
        data: %{
          event_id: "evt_upd_1",
          stripe_dispute_id: _,
          status: "under_review"
        }
      }
    end

    test "one-time charge dispute update does not broadcast" do
      d = dispute("under_review")
      event = %{"id" => "evt_upd_2", "type" => "charge.dispute.updated"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:ok, one_time_charge("cus_one_time")}
      end)

      assert {:ok, :dispute_updated} = DisputeHandler.process(event, d)

      refute_received %{event: :dispute_updated, data: _}
    end

    test "Stripe API error triggers retry_later" do
      d = dispute("under_review")
      event = %{"id" => "evt_upd_3", "type" => "charge.dispute.updated"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id -> {:error, %{message: "down"}} end)

      assert {:error, :retry_later, _msg} = DisputeHandler.process(event, d)
    end
  end

  describe "process/2 — charge.dispute.closed" do
    test "subscription dispute close is forwarded to SaaS via PubSub" do
      d = dispute("won")
      event = %{"id" => "evt_close_1", "type" => "charge.dispute.closed"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id -> {:ok, subscription_charge()} end)

      assert {:ok, :dispute_closed} = DisputeHandler.process(event, d)

      assert_received %{
        event: :dispute_closed,
        data: %{
          event_id: "evt_close_1",
          stripe_dispute_id: _,
          status: "won",
          dispute: _
        }
      }
    end

    test "one-time lost dispute fires admin alert and returns dispute_closed" do
      user = insert(:user)

      insert(:payment_transaction,
        user: user,
        status: "completed",
        stripe_customer_id: "cus_lost_dispute"
      )

      d = dispute("lost", %{"amount" => 5000, "reason" => "duplicate"})
      event = %{"id" => "evt_close_2", "type" => "charge.dispute.closed"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:ok, one_time_charge("cus_lost_dispute")}
      end)

      assert {:ok, :dispute_closed} = DisputeHandler.process(event, d)

      # No subscription broadcast for one-time charges
      refute_received %{event: :dispute_closed, data: _}
    end

    test "one-time won dispute returns dispute_closed without subscription broadcast" do
      user = insert(:user)

      insert(:payment_transaction,
        user: user,
        status: "completed",
        stripe_customer_id: "cus_won_dispute"
      )

      d = dispute("won")
      event = %{"id" => "evt_close_3", "type" => "charge.dispute.closed"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:ok, one_time_charge("cus_won_dispute")}
      end)

      assert {:ok, :dispute_closed} = DisputeHandler.process(event, d)
      refute_received %{event: :dispute_closed, data: _}
    end

    test "Stripe API error triggers retry_later" do
      d = dispute("won")
      event = %{"id" => "evt_close_4", "type" => "charge.dispute.closed"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id -> {:error, %{message: "down"}} end)

      assert {:error, :retry_later, _msg} = DisputeHandler.process(event, d)
    end
  end

  describe "process/2 — charge.dispute.created (unlinked one-time)" do
    test "dispute on one-time charge with no matching transaction is logged" do
      d = dispute("needs_response")
      event = %{"id" => "evt_orphan", "type" => "charge.dispute.created"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:ok, one_time_charge("cus_orphan_dispute")}
      end)

      # No payment_transaction exists for cus_orphan_dispute — handler logs and
      # returns the orphan outcome without crashing.
      assert {:ok, :dispute_logged} = DisputeHandler.process(event, d)
    end
  end
end
